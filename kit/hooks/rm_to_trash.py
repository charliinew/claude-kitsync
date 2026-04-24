#!/usr/bin/env python3
"""
Hook PreToolUse : remplace les commandes rm/* par trash.
Exemples :
  rm file        -> trash file
  rm -rf dir     -> trash dir
  rm -f a b      -> trash a b
"""
import json
import sys
import re

data = json.load(sys.stdin)
cmd = data.get('tool_input', {}).get('command', '')

# Remplace `rm` suivi d'options facultatives par `trash` (sans les flags)
new_cmd = re.sub(r'\brm(\s+-[rRfidvn]+)*\s+', 'trash ', cmd)

if new_cmd != cmd:
    print(json.dumps({
        'hookSpecificOutput': {
            'hookEventName': 'PreToolUse',
            'updatedInput': {'command': new_cmd}
        }
    }))
else:
    print('{}')
