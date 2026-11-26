#!/usr/bin/env python3
"""Fixtures for scripts/release-check-debug-args.sh (App Store completion §5).

Each case writes a scratch source tree and runs the guard against it: a debug-only launch argument or type
referenced outside an active `#if DEBUG` region must fail the check; the same reference inside one must pass.
Covers the GUI-walk simulated plan (`--ui-walk-simulated-plan=…`, UIWalkSimulatedPlan) and the older arguments.
Nothing here reads or changes the product's sources.
"""
import os
import subprocess
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
GUARD = os.path.join(HERE, "..", "release-check-debug-args.sh")


def run_guard(files):
    with tempfile.TemporaryDirectory() as tmp:
        src = os.path.join(tmp, "Source")
        os.makedirs(src)
        for name, text in files.items():
            with open(os.path.join(src, name), "w") as f:
                f.write(text)
        out = subprocess.run(["bash", GUARD, src], capture_output=True, text=True)
        return out.returncode, out.stdout + out.stderr


class DebugArgsGuardTests(unittest.TestCase):
    def test_simulated_plan_argument_outside_debug_fails(self):
        code, out = run_guard({"Launch.swift": 'let on = CommandLine.arguments.contains("--ui-walk-simulated-plan=aiIncluded")\n'})
        self.assertEqual(code, 1, out)
        self.assertIn("Launch.swift:1", out)

    def test_simulated_plan_type_outside_debug_fails(self):
        code, out = run_guard({"Provider.swift": "func f() {\n    if UIWalkSimulatedPlan.isActive { return }\n}\n"})
        self.assertEqual(code, 1, out)
        self.assertIn("Provider.swift:2", out)

    def test_in_the_else_branch_of_debug_fails(self):
        text = "#if DEBUG\nlet a = 1\n#else\nlet b = UIWalkSimulatedPlan.isActive\n#endif\n"
        code, out = run_guard({"Else.swift": text})
        self.assertEqual(code, 1, out)
        self.assertIn("Else.swift:4", out)

    def test_inside_a_non_debug_condition_fails(self):
        text = "#if os(macOS)\nlet b = UIWalkSimulatedPlan.isActive\n#endif\n"
        code, out = run_guard({"Os.swift": text})
        self.assertEqual(code, 1, out)

    def test_inside_debug_passes(self):
        text = ("#if DEBUG   // compiled out of Release\n"
                "let on = CommandLine.arguments.contains(\"--ui-walk-simulated-plan=aiPro\")\n"
                "#if os(macOS)\nlet b = UIWalkSimulatedPlan.isActive\n#endif\n"
                "#endif\n")
        code, out = run_guard({"Wrapped.swift": text})
        self.assertEqual(code, 0, out)

    def test_older_arguments_still_covered(self):
        code, out = run_guard({"Old.swift": 'let r = CommandLine.arguments.contains("--ui-walk-dummy-relay")\n'})
        self.assertEqual(code, 1, out)

    def test_the_product_sources_pass(self):
        out = subprocess.run(["bash", GUARD], capture_output=True, text=True)
        self.assertEqual(out.returncode, 0, out.stdout + out.stderr)


if __name__ == "__main__":
    unittest.main()
