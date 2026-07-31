#!/usr/bin/env python3
"""Validate the firewall rule config files before they reach Azure.

Every check here corresponds to something Azure rejects, or silently accepts
and then behaves confusingly, halfway through a 15 minute deployment.

Usage: python scripts/validate-firewall-rules.py [file ...]
       (no arguments validates every config/*/firewall_rules_*.json)
"""

import glob
import json
import os
import sys

# https://learn.microsoft.com/azure/azure-resource-manager/management/azure-subscription-service-limits#azure-firewall-limits
MAX_RULE_COLLECTION_GROUP_BYTES = 1024 * 1024  # 1 MB, policies created before July 2022
PRIORITY_MIN, PRIORITY_MAX = 100, 65000

SECTIONS = {
    'networkRules': 'FirewallPolicyFilterRuleCollection',
    'applicationRules': 'FirewallPolicyFilterRuleCollection',
    'dnatRules': 'FirewallPolicyNatRuleCollection',
}


def check_file(path):
    errors, warnings = [], []

    try:
        with open(path, encoding='utf-8') as fh:
            doc = json.load(fh)
    except json.JSONDecodeError as exc:
        return ["%s: invalid JSON: %s" % (path, exc)], []

    if not isinstance(doc, dict):
        return ["%s: expected a JSON object at the top level" % path], []

    unknown = set(doc) - set(SECTIONS)
    if unknown:
        errors.append("%s: unknown top-level key(s) %s; hub.template.json only "
                      "reads %s" % (path, sorted(unknown), sorted(SECTIONS)))

    for section, expected_type in SECTIONS.items():
        collections = doc.get(section)
        if collections is None:
            warnings.append("%s: no '%s' key; an empty rule collection group "
                            "will be deployed" % (path, section))
            continue
        if not isinstance(collections, list):
            errors.append("%s: '%s' must be an array" % (path, section))
            continue

        size = len(json.dumps(collections).encode('utf-8'))
        if size > MAX_RULE_COLLECTION_GROUP_BYTES:
            errors.append("%s: '%s' is %.2f MB, over the %d MB rule collection "
                          "group limit" % (path, section,
                                           size / 1024.0 / 1024,
                                           MAX_RULE_COLLECTION_GROUP_BYTES // 1024 // 1024))

        seen_priority, seen_name = {}, {}
        for index, collection in enumerate(collections):
            where = "%s: %s[%d]" % (path, section, index)

            if not isinstance(collection, dict):
                errors.append("%s: expected an object" % where)
                continue

            name = collection.get('name')
            if not name:
                errors.append("%s: missing 'name'" % where)
            elif name in seen_name:
                errors.append("%s: duplicate collection name '%s', also at index %d"
                              % (where, name, seen_name[name]))
            else:
                seen_name[name] = index

            priority = collection.get('priority')
            if priority is None:
                errors.append("%s ('%s'): missing 'priority'" % (where, name))
            elif not isinstance(priority, int):
                errors.append("%s ('%s'): priority must be an integer, got %r"
                              % (where, name, priority))
            elif not PRIORITY_MIN <= priority <= PRIORITY_MAX:
                errors.append("%s ('%s'): priority %d outside the allowed range %d-%d"
                              % (where, name, priority, PRIORITY_MIN, PRIORITY_MAX))
            elif priority in seen_priority:
                # Azure rejects the whole rule collection group for this.
                errors.append("%s ('%s'): duplicate priority %d, already used by '%s'"
                              % (where, name, priority, seen_priority[priority]))
            else:
                seen_priority[priority] = name

            collection_type = collection.get('ruleCollectionType')
            if collection_type != expected_type:
                errors.append("%s ('%s'): ruleCollectionType is %r, expected %r"
                              % (where, name, collection_type, expected_type))

            action = collection.get('action')
            if not isinstance(action, dict) or 'type' not in action:
                errors.append("%s ('%s'): missing action.type" % (where, name))

            rules = collection.get('rules')
            if not isinstance(rules, list):
                errors.append("%s ('%s'): 'rules' must be an array" % (where, name))
            elif not rules:
                # Deploys fine, matches nothing, and reads as an oversight.
                warnings.append("%s ('%s'): contains no rules" % (where, name))

    return errors, warnings


def main(argv):
    paths = argv[1:] or sorted(glob.glob(os.path.join('azure', '*', 'firewall_rules_*.json')))
    if not paths:
        print("No rule files found. Run from the repository root.")
        return 1

    total_errors = 0
    for path in paths:
        errors, warnings = check_file(path)
        total_errors += len(errors)
        status = "FAIL" if errors else "ok"
        print("%-4s %s (%d error(s), %d warning(s))" % (status, path, len(errors), len(warnings)))
        for message in errors:
            print("     ERROR   %s" % message)
        for message in warnings:
            print("     warning %s" % message)

    print()
    if total_errors:
        print("%d error(s) found." % total_errors)
        return 1
    print("All rule files valid.")
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv))
