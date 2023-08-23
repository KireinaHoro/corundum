#!/usr/bin/env python3

from jinja2 import Environment, FileSystemLoader
from argparse import ArgumentParser, ArgumentDefaultsHelpFormatter
from os.path import join, realpath, dirname
from math import ceil
import sys

GRPID_SHIFT = 12

parser = ArgumentParser(description='Compile templates for the PsPIN registers.', formatter_class=ArgumentDefaultsHelpFormatter)
parser.add_argument('name', type=str, help='name of the template to compile')
parser.add_argument('output', type=str, help='output file path')
parser.add_argument('--base-addr', type=int, help='register base address', default=0)
parser.add_argument('--word-size', type=int, help='size of native word', default=4)

args = parser.parse_args()

class RegSubGroup:
    next_alloc = 0

    def __init__(self, name, readonly, count, signal_width=args.word_size*8):
        self.name = name
        self.readonly = readonly
        self.count = count
        # only used when also generating Verilog ports
        # if > word_size, registers would be split
        # width is for a single register
        self.signal_width = signal_width

        self.glb_idx = RegSubGroup.next_alloc
        RegSubGroup.next_alloc += self.count

        # not populated yet
        self.base = None
        self.parent = None

        self.expanded = None
    
    def get_base_addr(self):
        global args
        if self.base >= (1 << GRPID_SHIFT):
            raise ValueError(f'base address {self.base:#x} exceeded regid field (12 bits)')
        return args.base_addr + (self.parent.grpid << GRPID_SHIFT) + self.base

    def get_signal_name(self):
        return f'{self.parent.name}_{self.name}'.upper()

    def expand(self):
        word_width = args.word_size * 8
        if not self.is_extended():
            ret = [self]
        else:
            num_words = int(ceil(self.signal_width / word_width))
            self.expanded = []
            for idx in range(num_words):
                self.expanded.append(RegSubGroup(
                    f'{self.name}_{idx}',
                    self.readonly,
                    self.count,
                    signal_width=None, # we only use signal width from unexpanded subgroups
                ))
            ret = self.expanded
        return ret

    def __repr__(self):
        if self.base is not None and self.signal_width:
            # normal register
            ret = f'<SubGroup "{self.name}" {self.readonly} x{self.count} @{self.base:#x} (width {self.signal_width})>'
        elif self.base and not self.signal_width:
            # expanded child
            ret = f'\t<ExpSubGroup "{self.name}" @{self.base:#x}>\n'
        else:
            # expanded parent
            ret = f'<SubGroup "{self.name}" {self.readonly} x{self.count} (width {self.signal_width})\n{self.expanded}>'
        return ret

    def is_extended(self):
        word_width = args.word_size * 8
        return self.signal_width > word_width

class RegGroup:
    next_alloc = 0

    def __init__(self, name, subgroups):
        global args

        self.name = name

        # used to generate signals
        self.subgroups = subgroups

        self.grpid = RegGroup.next_alloc
        RegGroup.next_alloc += 1

        # expand to concrete subgroups
        self.expanded = sum(map(lambda sg: sg.expand(), self.subgroups), start=[])

        # store parent reference for address calculation
        cur_base = 0
        for sg in self.expanded:
            sg.parent = self
            sg.base = cur_base
            cur_base += sg.count * args.word_size

    def reg_count(self):
        return sum(map(lambda sg: sg.count, self.subgroups))

    def __repr__(self):
        return '\n[' + ', \n'.join(map(str, self.subgroups)) + ']'
    
params = {
    'UMATCH_WIDTH': 32,
    'UMATCH_ENTRIES': 4,
    'UMATCH_RULESETS': 4,
    'UMATCH_MODES': 2,
    'HER_NUM_HANDLER_CTX': 4,
}

# TODO: document each register
groups = [
    RegGroup('cl', [
        RegSubGroup('ctrl',     False, 2),
        RegSubGroup('fifo',     True,  1),
    ]),
    RegGroup('stats', [
        RegSubGroup('cluster',  True,  2),
        RegSubGroup('mpq',      True,  1),
        RegSubGroup('datapath', True,  2),
    ]),
    RegGroup('me', [
        RegSubGroup('valid',    False, 1, 1),
        RegSubGroup('mode',     False, params['UMATCH_RULESETS'], params['UMATCH_MODES'].bit_length()),
        RegSubGroup('idx',      False, params['UMATCH_RULESETS'] * params['UMATCH_ENTRIES'], params['UMATCH_WIDTH']),
        RegSubGroup('mask',     False, params['UMATCH_RULESETS'] * params['UMATCH_ENTRIES'], params['UMATCH_WIDTH']),
        RegSubGroup('start',    False, params['UMATCH_RULESETS'] * params['UMATCH_ENTRIES'], params['UMATCH_WIDTH']),
        RegSubGroup('end',      False, params['UMATCH_RULESETS'] * params['UMATCH_ENTRIES'], params['UMATCH_WIDTH']),
    ]),
    RegGroup('her', [
        RegSubGroup('valid',              False, 1, 1),
        RegSubGroup('ctx_enabled',        False, params['HER_NUM_HANDLER_CTX'], 1),
    ]),
    RegGroup('her_meta', [
        RegSubGroup('handler_mem_addr',   False, params['HER_NUM_HANDLER_CTX']),
        RegSubGroup('handler_mem_size',   False, params['HER_NUM_HANDLER_CTX']),
        RegSubGroup('host_mem_addr',      False, params['HER_NUM_HANDLER_CTX'], 64),
        RegSubGroup('host_mem_size',      False, params['HER_NUM_HANDLER_CTX']),
        RegSubGroup('hh_addr',            False, params['HER_NUM_HANDLER_CTX']),
        RegSubGroup('hh_size',            False, params['HER_NUM_HANDLER_CTX']),
        RegSubGroup('ph_addr',            False, params['HER_NUM_HANDLER_CTX']),
        RegSubGroup('ph_size',            False, params['HER_NUM_HANDLER_CTX']),
        RegSubGroup('th_addr',            False, params['HER_NUM_HANDLER_CTX']),
        RegSubGroup('th_size',            False, params['HER_NUM_HANDLER_CTX']),
        RegSubGroup('scratchpad_0_addr',  False, params['HER_NUM_HANDLER_CTX']),
        RegSubGroup('scratchpad_0_size',  False, params['HER_NUM_HANDLER_CTX']),
        RegSubGroup('scratchpad_1_addr',  False, params['HER_NUM_HANDLER_CTX']),
        RegSubGroup('scratchpad_1_size',  False, params['HER_NUM_HANDLER_CTX']),
        RegSubGroup('scratchpad_2_addr',  False, params['HER_NUM_HANDLER_CTX']),
        RegSubGroup('scratchpad_2_size',  False, params['HER_NUM_HANDLER_CTX']),
        RegSubGroup('scratchpad_3_addr',  False, params['HER_NUM_HANDLER_CTX']),
        RegSubGroup('scratchpad_3_size',  False, params['HER_NUM_HANDLER_CTX']),
    ]),
]
    
# construct dict for template use
groups = {rg.name: rg for rg in groups}

templates_dir = join(dirname(realpath(__file__)), 'templates/')
print(f'Search path for templates: {templates_dir}', file=sys.stderr)
environment = Environment(loader=FileSystemLoader(templates_dir))

template = environment.get_template(args.name)
template_args = {
    'groups': groups,
    'num_regs': sum(map(lambda rg: rg.reg_count(), groups.values())),
    'params': params,
    'args': args,
}
content = template.render(template_args)

if args.output == '-':
    print(content)
else:
    with open(args.output, mode='w', encoding='utf-8') as f:
        f.write(content)