#ifndef __FPSPIN_REGS_GEN_H__
#define __FPSPIN_REGS_GEN_H__

{%- for k, v in params.items() %}
#define {{ k }} {{ v }}
{%- endfor %}

struct mqnic_app_pspin {
  struct device *dev;
  struct mqnic_dev *mdev;
  struct mqnic_adev *adev;

  struct device *nic_dev;

  void __iomem *nic_hw_addr;
  void __iomem *app_hw_addr;
  void __iomem *ram_hw_addr;

  bool in_reset;
  bool in_her_conf;
  bool in_me_conf;

  struct dma_area_int {
    void *cpu_addr;
    struct ctx_dma_area phys;
    int ref_count;
  } dma_areas[HER_NUM_HANDLER_CTX];
};

{#- inject check functions #}
{{- groups["me"].set_aux("check_me_in_conf") }}
{{- groups["me"].dict["valid"].set_aux("check_me_en") }}
{{- groups["her"].set_aux("check_her_in_conf") }}
{{- groups["her_meta"].set_aux("check_her_in_conf") }}
{{- groups["her"].dict["valid"].set_aux("check_her_en") }}
{{- groups["cl"].dict["ctrl"].set_aux("check_cl_ctrl") }}

// FIXME: move into app data?
{%- for rg in groups.values() %}
static struct kobject *dir_{{ rg.name }};
{%- for sg in rg.expanded %}
static struct attribute_group ag_{{ rg.name }}_{{ sg.name }};
{%- endfor %}

{%- endfor %}
#define REG_ADDR(app, name, _idx)                                              \
  REG(app, ATTR_REG_ADDR(                                                      \
               attr_to_pspin_dev_attr(ag_##name.attrs[_idx])))

static bool check_cl_ctrl(struct device *dev, u32 idx, u32 reg);
static bool check_me_en(struct device *dev, u32 idx, u32 reg);
static bool check_her_en(struct device *dev, u32 idx, u32 reg);
static bool check_me_in_conf(struct device *dev, u32 idx, u32 reg);
static bool check_her_in_conf(struct device *dev, u32 idx, u32 reg);

static ssize_t pspin_reg_show(struct device *dev, struct device_attribute *attr,
                              char *buf);
static ssize_t pspin_reg_store(struct device *dev,
                               struct device_attribute *attr, const char *buf,
                               size_t count);

static void remove_pspin_sysfs(void *data) {
{%- for rg in groups.values() %}
{%- for sg in rg.expanded %}
  sysfs_remove_group(dir_{{ rg.name }}, &ag_{{ rg.name }}_{{ sg.name }});
{%- endfor %}
  kobject_put(dir_{{ rg.name }});
{%- endfor %}
}

#define ATTR_NAME_LEN 32
static int init_pspin_sysfs(struct mqnic_app_pspin *app) {
  struct device *dev = app->dev;
  int i, ret;
  struct pspin_device_attribute *dev_attr;

{%- for rg in groups.values() %}
  dir_{{ rg.name }} = kobject_create_and_add("{{ rg.name }}", &dev->kobj);
{%- for sg in rg.expanded %}
{%- set ag = "ag_%s_%s" | format(rg.name, sg.name) %}
  {{ ag }}.name = "{{ sg.name }}";
  {{ ag }}.attrs = devm_kcalloc(dev, {{ sg.count + 1 }}, sizeof(void *), GFP_KERNEL);
  for (i = 0; i < {{ sg.count }}; ++i) {
    char *name_buf = (char *)devm_kzalloc(dev, ATTR_NAME_LEN, GFP_KERNEL);
    scnprintf(name_buf, ATTR_NAME_LEN, "%d", i);
    dev_attr =
        devm_kzalloc(dev, sizeof(struct pspin_device_attribute), GFP_KERNEL);
    dev_attr->dev_attr.attr.name = name_buf;
    dev_attr->dev_attr.attr.mode = {{ "0444" if sg.readonly else "0644" }};
    dev_attr->dev_attr.show = pspin_reg_show;
{%- if not sg.readonly %}
    dev_attr->dev_attr.store = pspin_reg_store;
{%- endif %}
    dev_attr->idx = i;
    dev_attr->offset = {{ "%#x" | format(sg.get_base_addr()) }};
    dev_attr->group_name = {{ ag }}.name;
    dev_attr->check_func = {{ sg.aux or "NULL" }};
    {{ ag }}.attrs[i] = (struct attribute *)dev_attr;
  }
  if ((ret = sysfs_create_group(dir_{{ rg.name }}, &{{ ag }}))) {
    dev_err(dev, "failed to create sysfs subgroup {{ ag }}\n");
    return ret;
  }
{%- endfor %}
{% endfor %}

  ret = devm_add_action_or_reset(dev, remove_pspin_sysfs, app);
  if (ret) {
    dev_err(dev, "failed to add cleanup action for sysfs nodes\n");
    return ret;
  }

  return ret;
}

#endif