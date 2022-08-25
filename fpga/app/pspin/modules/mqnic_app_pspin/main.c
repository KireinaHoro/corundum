// SPDX-License-Identifier: BSD-2-Clause-Views
/*
 * Copyright 2022, The Regents of the University of California.
 * All rights reserved.
 *
 * Redistribution and use in source and binary forms, with or without
 * modification, are permitted provided that the following conditions
 * are met:
 *
 *    1. Redistributions of source code must retain the above copyright
 *       notice, this list of conditions and the following disclaimer.
 *
 *    2. Redistributions in binary form must reproduce the above
 *       copyright notice, this list of conditions and the following
 *       disclaimer in the documentation and/or other materials provided
 *       with the distribution.
 *
 * THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS
 * "AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT
 * LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR
 * A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT
 * OWNER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL,
 * SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT
 * LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE,
 * DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY
 * THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
 * (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
 * OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
 *
 * The views and conclusions contained in the software and documentation
 * are those of the authors and should not be interpreted as representing
 * official policies, either expressed or implied, of The Regents of the
 * University of California.
 */

#include "mqnic.h"
#include <asm-generic/errno-base.h>
#include <asm-generic/errno.h>
#include <linux/init.h>
#include <linux/module.h>
#include <linux/moduleparam.h>
#include <linux/version.h>

#include <linux/cdev.h>
#include <linux/device.h>
#include <linux/err.h>
#include <linux/errno.h>
#include <linux/fs.h>
#include <linux/iopoll.h>
#include <linux/kernel.h>
#include <linux/mutex.h>
#include <linux/slab.h>
#include <linux/stat.h>

#include <linux/uaccess.h>

MODULE_DESCRIPTION("mqnic pspin driver");
MODULE_AUTHOR("Pengcheng Xu");
MODULE_LICENSE("Dual BSD/GPL");
MODULE_VERSION("0.1");

// We expose the mapped L2/prog mem address space to userspace as a single
// character-special file.  The userspace handler loader should undo the
// mapping correctly.
#define REG(app, offset) ((app)->app_hw_addr + 0x800000 + (offset))
#define R_CLUSTER_FETCH_EN(app) (REG(app, 0x0000))
#define R_CLUSTER_RESET(app) (REG(app, 0x0004))
#define R_CLUSTER_EOC(app) (REG(app, 0x0100))
#define R_CLUSTER_BUSY(app) (REG(app, 0x0104))
#define R_MPQ_BUSY_0(app) (REG(app, 0x0108))
#define R_MPQ_BUSY_1(app) (REG(app, 0x010c))
#define R_MPQ_BUSY_2(app) (REG(app, 0x0110))
#define R_MPQ_BUSY_3(app) (REG(app, 0x0114))
#define R_MPQ_BUSY_4(app) (REG(app, 0x0118))
#define R_MPQ_BUSY_5(app) (REG(app, 0x011c))
#define R_MPQ_BUSY_6(app) (REG(app, 0x0120))
#define R_MPQ_BUSY_7(app) (REG(app, 0x0124))
#define R_STDOUT_FIFO(app) (REG(app, 0x1000))

#define PSPIN_MEM(app, off) ((app)->app_hw_addr + (off))

#define PSPIN_DEVICE_NAME "pspin"
#define PSPIN_NUM_CLUSTERS 2L
struct mqnic_app_pspin {
  struct device *dev;
  struct mqnic_dev *mdev;
  struct mqnic_adev *adev;

  struct device *nic_dev;

  void __iomem *nic_hw_addr;
  void __iomem *app_hw_addr;
  void __iomem *ram_hw_addr;

  bool in_reset;
};

// NUM_CLUSTERS of 1 or 0
static ssize_t cl_fetch_en_store(struct device *dev,
                                 struct device_attribute *attr, const char *buf,
                                 size_t count) {
  struct mqnic_app_pspin *app = dev_get_drvdata(dev);
  u32 reg = 0;
  int i;

  if (count != PSPIN_NUM_CLUSTERS) {
    dev_err(dev, "%s(): cluster count mismatch: expected %ld, got %ld\n",
            __func__, PSPIN_NUM_CLUSTERS, count);
    return -EINVAL;
  }

  for (i = 0; i < PSPIN_NUM_CLUSTERS; ++i) {
    if (buf[i] == '1')
      reg |= 1 << i;
  }
  iowrite32(reg, R_CLUSTER_FETCH_EN(app));

  return count;
}

static ssize_t cl_rst_store(struct device *dev, struct device_attribute *attr,
                            const char *buf, size_t count) {
  struct mqnic_app_pspin *app = dev_get_drvdata(dev);
  u32 reg = 0;

  if (count != 1) {
    dev_err(dev, "%s(): count mismatch: expected %ld, got %ld\n",
            __func__, 1L, count);
    return -EINVAL;
  }

  if (buf[0] == '1')
    reg = 1;
  iowrite32(reg, R_CLUSTER_RESET(app));
  app->in_reset = reg;

  return count;
}

static ssize_t cl_eoc_show(struct device *dev, struct device_attribute *attr,
                           char *buf) {
  struct mqnic_app_pspin *app = dev_get_drvdata(dev);

  return scnprintf(buf, PAGE_SIZE, "0x%08x\n", ioread32(R_CLUSTER_EOC(app)));
}

static ssize_t cl_busy_show(struct device *dev, struct device_attribute *attr,
                            char *buf) {
  struct mqnic_app_pspin *app = dev_get_drvdata(dev);

  return scnprintf(buf, PAGE_SIZE, "0x%08x\n", ioread32(R_CLUSTER_BUSY(app)));
}

static ssize_t mpq_full_show(struct device *dev, struct device_attribute *attr,
                             char *buf) {
  struct mqnic_app_pspin *app = dev_get_drvdata(dev);

  ssize_t count = 0;

  count += scnprintf(buf + count, PAGE_SIZE - count, "0x%08x\n",
                     ioread32(R_MPQ_BUSY_0(app)));
  count += scnprintf(buf + count, PAGE_SIZE - count, "0x%08x\n",
                     ioread32(R_MPQ_BUSY_1(app)));
  count += scnprintf(buf + count, PAGE_SIZE - count, "0x%08x\n",
                     ioread32(R_MPQ_BUSY_2(app)));
  count += scnprintf(buf + count, PAGE_SIZE - count, "0x%08x\n",
                     ioread32(R_MPQ_BUSY_3(app)));
  count += scnprintf(buf + count, PAGE_SIZE - count, "0x%08x\n",
                     ioread32(R_MPQ_BUSY_4(app)));
  count += scnprintf(buf + count, PAGE_SIZE - count, "0x%08x\n",
                     ioread32(R_MPQ_BUSY_5(app)));
  count += scnprintf(buf + count, PAGE_SIZE - count, "0x%08x\n",
                     ioread32(R_MPQ_BUSY_6(app)));
  count += scnprintf(buf + count, PAGE_SIZE - count, "0x%08x\n",
                     ioread32(R_MPQ_BUSY_7(app)));

  return count;
}

static struct device_attribute dev_attr_cl_fetch_en = __ATTR_WO(cl_fetch_en);
static struct device_attribute dev_attr_cl_rst = __ATTR_WO(cl_rst);
static struct device_attribute dev_attr_cl_eoc = __ATTR_RO(cl_eoc);
static struct device_attribute dev_attr_cl_busy = __ATTR_RO(cl_busy);
static struct device_attribute dev_attr_mpq_full = __ATTR_RO(mpq_full);

struct pspin_cdev {
  enum {
    TY_MEM,
    TY_FIFO,
  } type;
  struct mqnic_app_pspin *app;
  unsigned char *block_buffer;
  struct mutex pspin_mutex;
  struct cdev cdev;
  struct device *dev;
};

static int pspin_ndevices = 2;
static unsigned long pspin_block_size = 512;
// only checked for mem, stdout is assumed to be unbounded
static unsigned long pspin_mem_size = 0x200000;

static unsigned int pspin_major = 0;
static struct pspin_cdev *pspin_cdevs = NULL;
static struct class *pspin_class = NULL;

int pspin_open(struct inode *inode, struct file *filp) {
  unsigned mj = imajor(inode);
  unsigned mn = iminor(inode);

  struct pspin_cdev *dev = NULL;
  struct device *d;

  if (mj != pspin_major || mn < 0 || mn >= pspin_ndevices) {
    printk(KERN_WARNING "No character device found with %d:%d\n", mj, mn);
    return -ENODEV;
  }

  // prevent operation on mem if in reset
  if (dev->type == TY_MEM && dev->app->in_reset) {
    printk(KERN_WARNING "PsPIN cluster in reset, rejecting\n");
    return -EPERM;
  }

  dev = &pspin_cdevs[mn];
  filp->private_data = dev;
  d = dev->dev;

  if (inode->i_cdev != &dev->cdev) {
    dev_warn(d, "open: internal error\n");
    return -ENODEV;
  }

  if (dev->block_buffer == NULL) {
    dev->block_buffer =
        (unsigned char *)devm_kzalloc(d, pspin_block_size, GFP_KERNEL);
    if (dev->block_buffer == NULL) {
      dev_warn(d, "open: out of memory\n");
      return -ENOMEM;
    }
  }
  return 0;
}

int pspin_release(struct inode *inode, struct file *filp) { return 0; }

DECLARE_WAIT_QUEUE_HEAD(stdout_read_queue);
ssize_t pspin_read(struct file *filp, char __user *buf, size_t count,
                   loff_t *f_pos) {
  struct pspin_cdev *dev = (struct pspin_cdev *)filp->private_data;
  struct mqnic_app_pspin *app = dev->app;
  ssize_t retval = 0;
  int i;

  // prevent operation on mem if in reset
  if (dev->type == TY_MEM && dev->app->in_reset) {
    printk(KERN_WARNING "PsPIN cluster in reset, rejecting\n");
    return -EPERM;
  }

  if (mutex_lock_killable(&dev->pspin_mutex))
    return -EINTR;
  if (dev->type == TY_MEM && *f_pos >= pspin_mem_size)
    goto out;
  if (dev->type == TY_MEM && *f_pos + count > pspin_mem_size)
    count = pspin_mem_size - *f_pos;
  if (count > pspin_block_size)
    count = pspin_block_size;
  if (dev->type == TY_MEM)
    count = round_down(count, 4);

  if (dev->type == TY_MEM) {
    for (i = 0; i < count; i += 4) {
      *((u32 *)&dev->block_buffer[i]) =
          ioread32(PSPIN_MEM(app, *f_pos + count));
    }
    retval = count;
  } else {
    u32 reg;
    uintptr_t off = 0;
    // read at least one first so we don't trigger EOF
    retval = wait_event_interruptible(stdout_read_queue, (reg = ioread32(R_STDOUT_FIFO(app))) != ~0);
    if (retval < 0)
      goto out;

    dev->block_buffer[off++] = (unsigned char)reg;

    while ((reg = ioread32(R_STDOUT_FIFO(app))) != ~0 && off < pspin_block_size)
      dev->block_buffer[off++] = (unsigned char)reg;
    retval = off;
  }

  if (copy_to_user(buf, dev->block_buffer, retval) != 0) {
    retval = -EFAULT;
    goto out;
  }

  if (dev->type == TY_MEM)
    *f_pos += retval;
out:
  mutex_unlock(&dev->pspin_mutex);
  return retval;
}

ssize_t pspin_write(struct file *filp, const char __user *buf, size_t count,
                    loff_t *f_pos) {
  struct pspin_cdev *dev = (struct pspin_cdev *)filp->private_data;
  struct mqnic_app_pspin *app = dev->app;
  ssize_t retval = 0;
  int i;

  if (dev->type == TY_FIFO) {
    dev_warn(dev->dev, "stdout FIFO does not support writing\n");
    return -EINVAL;
  }

  // prevent operation on mem if in reset
  if (dev->type == TY_MEM && dev->app->in_reset) {
    printk(KERN_WARNING "PsPIN cluster in reset, rejecting\n");
    return -EPERM;
  }

  if (mutex_lock_killable(&dev->pspin_mutex))
    return -EINTR;

  if (*f_pos >= pspin_mem_size) {
    retval = -EINVAL;
    goto out;
  }

  if (*f_pos + count > pspin_mem_size)
    count = pspin_mem_size - *f_pos;
  if (count > pspin_block_size)
    count = pspin_block_size;
  count = round_down(count, 4);

  if (copy_from_user(dev->block_buffer, buf, count) != 0) {
    retval = -EFAULT;
    goto out;
  }

  for (i = 0; i < count; i += 4) {
    iowrite32(*((u32 *)&dev->block_buffer[i]), PSPIN_MEM(app, count));
  }
  *f_pos += count;
  retval = count;

out:
  mutex_unlock(&dev->pspin_mutex);
  return retval;
}

loff_t pspin_llseek(struct file *filp, loff_t off, int whence) {
  struct pspin_cdev *dev = (struct pspin_cdev *)filp->private_data;
  loff_t newpos = 0;

  if (dev->type == TY_FIFO) {
    dev_warn(dev->dev, "stdout FIFO does not support seeking\n");
    return -EINVAL;
  }

  // prevent operation on mem if in reset
  if (dev->type == TY_MEM && dev->app->in_reset) {
    printk(KERN_WARNING "PsPIN cluster in reset, rejecting\n");
    return -EPERM;
  }

  switch (whence) {
  case SEEK_SET:
    newpos = off;
    break;
  case SEEK_CUR:
    newpos = filp->f_pos + off;
    break;
  case SEEK_END:
    newpos = pspin_mem_size + off;
    break;
  default: // not supported
    return -EINVAL;
  }
  if (newpos < 0 || newpos > pspin_mem_size)
    return -EINVAL;
  filp->f_pos = newpos;
  return newpos;
}

struct file_operations pspin_fops = {
    .owner = THIS_MODULE,
    .read = pspin_read,
    .write = pspin_write,
    .open = pspin_open,
    .release = pspin_release,
    .llseek = pspin_llseek,
};

static int pspin_construct_device(struct pspin_cdev *dev, int minor,
                                  struct class *class,
                                  struct mqnic_app_pspin *app) {
  int err = 0;
  dev_t devno = MKDEV(pspin_major, minor);

  BUG_ON(dev == NULL || class == NULL);
  BUG_ON(minor < 0 || minor >= 2);

  dev->block_buffer = NULL;
  dev->app = app;
  mutex_init(&dev->pspin_mutex);
  cdev_init(&dev->cdev, &pspin_fops);
  dev->cdev.owner = THIS_MODULE;
  dev->type = minor == 0 ? TY_MEM : TY_FIFO;

  err = cdev_add(&dev->cdev, devno, 1);
  if (err) {
    printk(KERN_WARNING "error %d while trying to add %s%d", err,
           PSPIN_DEVICE_NAME, minor);
    return err;
  }

  dev->dev =
      device_create(class, NULL, devno, NULL, PSPIN_DEVICE_NAME "%d", minor);
  if (IS_ERR(dev->dev)) {
    err = PTR_ERR(dev->dev);
    printk(KERN_WARNING "error %d while trying to create %s%d", err,
           PSPIN_DEVICE_NAME, minor);
    cdev_del(&dev->cdev);
    return err;
  }
  return 0;
}

static void pspin_destroy_device(struct pspin_cdev *dev, int minor,
                                 struct class *class) {
  BUG_ON(dev == NULL || class == NULL);
  BUG_ON(minor < 0 || minor >= 2);

  device_destroy(class, MKDEV(pspin_major, minor));
  cdev_del(&dev->cdev);
  mutex_destroy(&dev->pspin_mutex);
}

static void pspin_cleanup_chrdev(int devices_to_destroy) {
  int i;

  if (pspin_cdevs) {
    for (i = 0; i < devices_to_destroy; ++i)
      pspin_destroy_device(&pspin_cdevs[i], i, pspin_class);
  }

  if (pspin_class)
    class_destroy(pspin_class);

  unregister_chrdev_region(MKDEV(pspin_major, 0), pspin_ndevices);
}

static int mqnic_app_pspin_probe(struct auxiliary_device *adev,
                                 const struct auxiliary_device_id *id) {
  struct mqnic_dev *mdev = container_of(adev, struct mqnic_adev, adev)->mdev;
  struct device *dev = &adev->dev;

  struct mqnic_app_pspin *app;

  int err = 0;
  int i = 0;
  int devices_to_destroy = 0;
  dev_t devno = 0;

  dev_info(dev, "%s() called", __func__);

  if (!mdev->hw_addr || !mdev->app_hw_addr) {
    dev_err(dev,
            "Error: required region not present: hw_addr %p, app_hw_addr %p\n",
            mdev->hw_addr, mdev->app_hw_addr);
    return -EIO;
  }

  app = devm_kzalloc(dev, sizeof(*app), GFP_KERNEL);
  if (!app)
    return -ENOMEM;

  app->dev = dev;
  app->mdev = mdev;
  dev_set_drvdata(&adev->dev, app);

  app->nic_dev = mdev->dev;
  app->nic_hw_addr = mdev->hw_addr;
  app->app_hw_addr = mdev->app_hw_addr;
  app->ram_hw_addr = mdev->ram_hw_addr;

  // device started up in reset
  app->in_reset = true;

  // setup character special devices
  if (pspin_ndevices <= 0) {
    printk(KERN_WARNING "invalid value of pspin_ndevices: %d\n",
           pspin_ndevices);
    return -EINVAL;
  }

  err = alloc_chrdev_region(&devno, 0, pspin_ndevices, PSPIN_DEVICE_NAME);
  if (err < 0) {
    printk(KERN_WARNING "alloc_chrdev_region() failed\n");
    return err;
  }
  pspin_major = MAJOR(devno);

  pspin_class = class_create(THIS_MODULE, PSPIN_DEVICE_NAME);
  if (IS_ERR(pspin_class)) {
    err = PTR_ERR(pspin_class);
    goto fail;
  }

  pspin_cdevs = (struct pspin_cdev *)devm_kzalloc(
      dev, pspin_ndevices * sizeof(struct pspin_cdev), GFP_KERNEL);
  if (pspin_cdevs == NULL) {
    err = -ENOMEM;
    goto fail;
  }

  for (i = 0; i < pspin_ndevices; ++i) {
    err = pspin_construct_device(&pspin_cdevs[i], i, pspin_class, app);
    if (err) {
      devices_to_destroy = i;
      goto fail;
    }
  }
  devices_to_destroy = pspin_ndevices;

  // control registers
  err = device_create_file(dev, &dev_attr_cl_fetch_en);
  if (err)
    goto fail;
  err = device_create_file(dev, &dev_attr_cl_rst);
  if (err)
    goto fail;
  err = device_create_file(dev, &dev_attr_cl_eoc);
  if (err)
    goto fail;
  err = device_create_file(dev, &dev_attr_cl_busy);
  if (err)
    goto fail;
  err = device_create_file(dev, &dev_attr_mpq_full);
  if (err)
    goto fail;

  return 0;

fail:
  device_remove_file(dev, &dev_attr_cl_fetch_en);
  device_remove_file(dev, &dev_attr_cl_rst);
  device_remove_file(dev, &dev_attr_cl_eoc);
  device_remove_file(dev, &dev_attr_cl_busy);
  device_remove_file(dev, &dev_attr_mpq_full);

  pspin_cleanup_chrdev(devices_to_destroy);
  return err;
}

static void mqnic_app_pspin_remove(struct auxiliary_device *adev) {
  struct mqnic_app_pspin *app = dev_get_drvdata(&adev->dev);
  struct device *dev = app->dev;

  dev_info(dev, "%s() called", __func__);

  device_remove_file(dev, &dev_attr_cl_fetch_en);
  device_remove_file(dev, &dev_attr_cl_rst);
  device_remove_file(dev, &dev_attr_cl_eoc);
  device_remove_file(dev, &dev_attr_cl_busy);
  device_remove_file(dev, &dev_attr_mpq_full);

  pspin_cleanup_chrdev(pspin_ndevices);
}

static const struct auxiliary_device_id mqnic_app_pspin_id_table[] = {
    {.name = "mqnic.app_12340100"},
    {},
};

MODULE_DEVICE_TABLE(auxiliary, mqnic_app_pspin_id_table);

static struct auxiliary_driver mqnic_app_pspin_driver = {
    .name = "mqnic_app_pspin",
    .probe = mqnic_app_pspin_probe,
    .remove = mqnic_app_pspin_remove,
    .id_table = mqnic_app_pspin_id_table,
};

static int __init mqnic_app_pspin_init(void) {
  return auxiliary_driver_register(&mqnic_app_pspin_driver);
}

static void __exit mqnic_app_pspin_exit(void) {
  auxiliary_driver_unregister(&mqnic_app_pspin_driver);
}

module_init(mqnic_app_pspin_init);
module_exit(mqnic_app_pspin_exit);
