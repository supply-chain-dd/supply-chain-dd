# Conforma (Enterprise Contract) Rego rule for SBOM baseline comparison.
#
# This rule checks that an SBOM is attached to the image (via OCI referrers)
# and that its package list matches a known-good baseline. Unexpected packages
# indicate potential supply chain tampering (e.g., base image poisoning).
#
# Usage with ec CLI (post-pipeline):
#   ec validate image \
#     --images '{"components":[{"name":"recipe-api","containerImage":"<image>@sha256:<digest>"}]}' \
#     --policy '{"sources":[{"name":"sbom-baseline","policy":["./challenges/challenge3/security/conforma-policies/"]}]}' \
#     --output text
#
# In Konflux, this runs as part of an IntegrationTestScenario.

package sbom_baseline

import rego.v1

# METADATA
# title: SBOM must be attached to image
# description: Verifies that an SBOM artifact exists as an OCI referrer
# custom:
#   short_name: sbom_attached
#   failure_msg: "No SBOM attestation found for image %s"
deny contains result if {
	some component in input.components
	not _has_sbom(component)
	result := {
		"code": "sbom_baseline.sbom_attached",
		"msg": sprintf("No SBOM attestation found for image %s", [component.containerImage]),
	}
}

# METADATA
# title: SBOM packages must match baseline
# description: Compares current SBOM packages against a known-good baseline
# custom:
#   short_name: sbom_packages_match_baseline
#   failure_msg: "Unexpected packages found in SBOM: %v"
deny contains result if {
	some component in input.components
	sbom := _get_sbom(component)
	current_packages := {pkg.name | some pkg in sbom.packages}
	baseline_packages := {pkg | some pkg in data.baseline_packages}
	unexpected := current_packages - baseline_packages
	count(unexpected) > 0
	result := {
		"code": "sbom_baseline.sbom_packages_match_baseline",
		"msg": sprintf("Unexpected packages found in SBOM for %s: %v", [component.containerImage, unexpected]),
	}
}

# METADATA
# title: No missing baseline packages
# description: Warns if expected baseline packages are absent from the SBOM
# custom:
#   short_name: sbom_no_missing_packages
#   failure_msg: "Baseline packages missing from SBOM: %v"
warn contains result if {
	some component in input.components
	sbom := _get_sbom(component)
	current_packages := {pkg.name | some pkg in sbom.packages}
	baseline_packages := {pkg | some pkg in data.baseline_packages}
	missing := baseline_packages - current_packages
	count(missing) > 0
	result := {
		"code": "sbom_baseline.sbom_no_missing_packages",
		"msg": sprintf("Baseline packages missing from SBOM for %s: %v", [component.containerImage, missing]),
	}
}

_has_sbom(component) if {
	some att in component.attestations
	att.predicateType == "https://spdx.dev/Document"
}

_get_sbom(component) := sbom if {
	some att in component.attestations
	att.predicateType == "https://spdx.dev/Document"
	sbom := att.predicate
}
