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
#define UMATCH_RULESETS 4
#define UMATCH_ENTRIES 4
#define HER_NUM_HANDLER_CTX 4
#define PSPIN_DEVICE_NAME "pspin"
#define PSPIN_NUM_CLUSTERS 2
struct mqnic_app_pspin {
  struct device *dev;
  struct mqnic_dev *mdev;
  struct mqnic_adev *adev;

  struct device *nic_dev;

  void __iomem *nic_hw_addr;
  void __iomem *app_hw_addr;
  void __iomem *ram_hw_addr;

  const struct attribute_group **groups;

  bool in_reset;
};

#define REG(app, offset) ((app)->app_hw_addr + 0x800000 + (offset))
#define PSPIN_MEM(app, off) ((app)->app_hw_addr + (off))

// X(name, count, ro, offset, check_func)
#define REG_DECLS(X)                                                           \
  X(cl_ctrl, 2, false, 0x0000, check_cl_ctrl)                                  \
  X(me_valid, 1, false, 0x2000, NULL)                                          \
  X(me_mode, UMATCH_RULESETS, false, 0x2100, NULL)                             \
  X(me_idx, UMATCH_ENTRIES *UMATCH_RULESETS, false, 0x2200, NULL)              \
  X(me_mask, UMATCH_ENTRIES *UMATCH_RULESETS, false, 0x2300, NULL)             \
  X(me_start, UMATCH_ENTRIES *UMATCH_RULESETS, false, 0x2400, NULL)            \
  X(me_end, UMATCH_ENTRIES *UMATCH_RULESETS, false, 0x2500, NULL)              \
  X(her, 1, false, 0x3000, NULL)                                               \
  X(her_ctx_enabled, HER_NUM_HANDLER_CTX, false, 0x3100, NULL)                 \
  X(her_handler_mem_addr, HER_NUM_HANDLER_CTX, false, 0x3200, NULL)            \
  X(her_handler_mem_size, HER_NUM_HANDLER_CTX, false, 0x3300, NULL)            \
  X(her_host_mem_addr_lo, HER_NUM_HANDLER_CTX, false, 0x3400, NULL)            \
  X(her_host_mem_addr_hi, HER_NUM_HANDLER_CTX, false, 0x3500, NULL)            \
  X(her_host_mem_size, HER_NUM_HANDLER_CTX, false, 0x3600, NULL)               \
  X(her_hh_addr, HER_NUM_HANDLER_CTX, false, 0x3700, NULL)                     \
  X(her_hh_size, HER_NUM_HANDLER_CTX, false, 0x3800, NULL)                     \
  X(her_ph_addr, HER_NUM_HANDLER_CTX, false, 0x3900, NULL)                     \
  X(her_ph_size, HER_NUM_HANDLER_CTX, false, 0x3a00, NULL)                     \
  X(her_th_addr, HER_NUM_HANDLER_CTX, false, 0x3b00, NULL)                     \
  X(her_th_size, HER_NUM_HANDLER_CTX, false, 0x3c00, NULL)                     \
  X(her_scratchpad_0_addr, HER_NUM_HANDLER_CTX, false, 0x3d00, NULL)           \
  X(her_scratchpad_0_size, HER_NUM_HANDLER_CTX, false, 0x3e00, NULL)           \
  X(her_scratchpad_1_addr, HER_NUM_HANDLER_CTX, false, 0x3f00, NULL)           \
  X(her_scratchpad_1_size, HER_NUM_HANDLER_CTX, false, 0x4000, NULL)           \
  X(her_scratchpad_2_addr, HER_NUM_HANDLER_CTX, false, 0x4100, NULL)           \
  X(her_scratchpad_2_size, HER_NUM_HANDLER_CTX, false, 0x4200, NULL)           \
  X(her_scratchpad_3_addr, HER_NUM_HANDLER_CTX, false, 0x4300, NULL)           \
  X(her_scratchpad_3_size, HER_NUM_HANDLER_CTX, false, 0x4400, NULL)           \
  X(datapath_stats, 2, true, 0x2600, NULL)                                     \
  X(cl_stat, 2, true, 0x0100, NULL)                                            \
  X(mpq, 1, true, 0x0200, NULL)                                                \
  X(fifo, 1, true, 0x1000, NULL)

enum {
#define IDX_REGS(name, count, ro, offset, check_func) IDX_##name,
  REG_DECLS(IDX_REGS) IDX_guard
};
static const struct attribute_group *attr_groups[IDX_guard + 1];

#define ATTR_REG_ADDR(_pspin_dev_attr)                                         \
  (_pspin_dev_attr)->offset + (_pspin_dev_attr)->idx * 4
#define REG_ADDR(app, name, _idx)                                              \
  REG(app, ATTR_REG_ADDR(                                                      \
               attr_to_pspin_dev_attr(attr_groups[IDX_##name]->attrs[_idx])))

bool check_cl_ctrl(struct device *dev, u32 idx, u32 reg) {
  u32 clusters = reg ? 32 - __builtin_clz(reg) : 0;
  struct mqnic_app_pspin *app = (struct mqnic_app_pspin *)dev->driver_data;
  if (idx != 0 && reg > 1) {
    dev_err(dev, "reset only takes 0 or 1; got %u\n", reg);
    return false;
  } else if (clusters > PSPIN_NUM_CLUSTERS) {
    dev_err(dev, "%d clusters exist, got %d to enable (reg = %#x)\n",
            PSPIN_NUM_CLUSTERS, clusters, reg);
    return false;
  }
  // FIXME: ideally after setting the register
  if (idx != 0) {
    app->in_reset = !!reg;
  }
  return true;
}

struct pspin_device_attribute {
  struct device_attribute dev_attr;
  u32 idx;                // index of register in block
  u32 offset;             // offset of block
  const char *group_name; // name of the group
  bool (*check_func)(struct device *, u32, u32);
};
#define to_pspin_dev_attr(_dev_attr)                                           \
  container_of(_dev_attr, struct pspin_device_attribute, dev_attr)
#define attr_to_pspin_dev_attr(_attr)                                          \
  to_pspin_dev_attr(container_of(_attr, struct device_attribute, attr))

static ssize_t pspin_reg_store(struct device *dev,
                               struct device_attribute *attr, const char *buf,
                               size_t count) {
  struct mqnic_app_pspin *app = dev_get_drvdata(dev);
  struct pspin_device_attribute *dev_attr = to_pspin_dev_attr(attr);
  u32 off = ATTR_REG_ADDR(dev_attr);
  u32 reg = 0;
  sscanf(buf, "%u\n", &reg);
  if (dev_attr->check_func && !dev_attr->check_func(dev, dev_attr->idx, reg)) {
    dev_err(dev, "check failed for %s%s\n", dev_attr->group_name,
            attr->attr.name);
    return -EINVAL;
  }
  iowrite32(reg, REG(app, off));
  return count;
}

static ssize_t pspin_reg_show(struct device *dev, struct device_attribute *attr,
                              char *buf) {
  struct mqnic_app_pspin *app = dev_get_drvdata(dev);
  struct pspin_device_attribute *dev_attr = to_pspin_dev_attr(attr);
  u32 off = ATTR_REG_ADDR(dev_attr);
  return scnprintf(buf, PAGE_SIZE, "%u\n", ioread32(REG(app, off)));
}

static void remove_pspin_sysfs(void *data) {
  struct mqnic_app_pspin *app = data;
  device_remove_groups(app->dev, app->groups);
}

#define ATTR_NAME_LEN 32
static int init_pspin_sysfs(struct mqnic_app_pspin *app) {
  struct device *dev = app->dev;
  int i, ret;
  struct pspin_device_attribute *dev_attr;
  struct attribute_group *group;
#define DEFINE_ATTR(_name, _count, _ro, _offset, _check_func)                  \
  group = (struct attribute_group *)devm_kzalloc(                              \
      dev, sizeof(struct attribute_group), GFP_KERNEL);                        \
  group->name = #_name;                                                        \
  group->attrs = (struct attribute **)devm_kcalloc(                            \
      dev, _count + 1, sizeof(void *), GFP_KERNEL);                            \
  for (i = 0; i < _count; ++i) {                                               \
    char *name_buf = (char *)devm_kzalloc(dev, ATTR_NAME_LEN, GFP_KERNEL);     \
    scnprintf(name_buf, ATTR_NAME_LEN, "%d", i);                               \
    dev_attr = (struct pspin_device_attribute *)devm_kzalloc(                  \
        dev, sizeof(struct pspin_device_attribute), GFP_KERNEL);               \
    dev_attr->dev_attr.attr.name = name_buf;                                   \
    dev_attr->dev_attr.attr.mode = _ro ? 0444 : 0644;                          \
    dev_attr->dev_attr.show = pspin_reg_show;                                  \
    if (!_ro)                                                                  \
      dev_attr->dev_attr.store = pspin_reg_store;                              \
    dev_attr->idx = i;                                                         \
    dev_attr->offset = _offset;                                                \
    dev_attr->group_name = group->name;                                        \
    dev_attr->check_func = _check_func;                                        \
    group->attrs[i] = (struct attribute *)dev_attr;                            \
  }                                                                            \
  attr_groups[IDX_##_name] = group;

  REG_DECLS(DEFINE_ATTR)

  app->groups = attr_groups;

  ret = device_add_groups(dev, attr_groups);
  if (ret) {
    dev_err(dev, "failed to create ctrl regs sysfs nodes\n");
    return ret;
  }

  ret = devm_add_action_or_reset(dev, remove_pspin_sysfs, app);
  if (ret) {
    dev_err(dev, "failed to add cleanup action for sysfs nodes\n");
    return ret;
  }

  return ret;
}

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
static unsigned long pspin_block_size = 4096;
// only checked for mem, stdout is assumed to be unbounded
// XXX: actually larger than memory!
// TODO: check for holes
static unsigned long pspin_mem_size = 0x800000;

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

  dev = &pspin_cdevs[mn];
  filp->private_data = dev;
  d = dev->dev;

  // prevent operation on mem if in reset
  if (dev->type == TY_MEM && dev->app->in_reset) {
    dev_warn(dev->dev, "PsPIN cluster in reset, rejecting\n");
    return -EPERM;
  }

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
    dev_warn(dev->dev, "PsPIN cluster in reset, rejecting\n");
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
      *((u32 *)&dev->block_buffer[i]) = ioread32(PSPIN_MEM(app, *f_pos + i));
    }
    retval = count;
  } else {
    u32 reg;
    uintptr_t off = 0;

    // TODO: demultiplex stdout stream in kernel (and use dedicated pspin_stdout
    // device) with deferred work

    // read at least one first so we don't trigger EOF
    do {
      retval = wait_event_interruptible_timeout(
          stdout_read_queue, (reg = ioread32(REG_ADDR(app, fifo, 0))) != ~0,
          usecs_to_jiffies(50));
    } while (!retval);
    if (retval == -ERESTARTSYS)
      goto out;
    *((u32 *)&dev->block_buffer[off]) = reg;
    off += 4;

    while ((reg = ioread32(REG_ADDR(app, fifo, 0))) != ~0 &&
           off < pspin_block_size) {
      *((u32 *)&dev->block_buffer[off]) = reg;
      off += 4;
    }
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
    dev_warn(dev->dev, "PsPIN cluster in reset, rejecting\n");
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
    iowrite32(*((u32 *)&dev->block_buffer[i]), PSPIN_MEM(app, *f_pos + i));
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
    dev_warn(dev->dev, "PsPIN cluster in reset, rejecting\n");
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
  if (newpos < 0 || newpos > pspin_mem_size) {
    dev_warn(dev->dev,
             "seek outside bounds: newpos=%#llx pspin_mem_size=%#lx\n", newpos,
             pspin_mem_size);
    return -EINVAL;
  }
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
  dev->driver_data = app;
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

  err = init_pspin_sysfs(app);
  if (err)
    goto fail;

  return 0;

fail:
  pspin_cleanup_chrdev(devices_to_destroy);
  return err;
}

static void mqnic_app_pspin_remove(struct auxiliary_device *adev) {
  struct mqnic_app_pspin *app = dev_get_drvdata(&adev->dev);
  struct device *dev = app->dev;

  dev_info(dev, "%s() called", __func__);

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
