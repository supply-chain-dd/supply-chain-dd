#!/usr/bin/env bash

cd challenges/e2e-scenario
./e2e-demo.sh
cd ../challenge1
./attack-demo.sh
./kubescape-demo.sh
./sourcetool-demo.sh
cd ../challenge2
./attack-demo.sh
./defense-demo.sh
./keyless-signing-demo.sh
cd ../challenge3
./attack-demo.sh
./sbom-comparison-demo.sh
./defense-demo.sh
cd ../challenge4
./conforma-ampel-demo.sh