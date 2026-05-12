  --- Source: https://lobehub.com/skills/konflux-ci-skills-understanding-konflux-resources?activeTab=version
  # Konflux's Key Isolation Architecture
  
  Konflux uses a three-layer namespace separation to keep signing keys away from build pipelines:

  1. Tekton Chains runs as a cluster-level controller, not in the build pipeline

  The critical design: signing does NOT happen inside the build pipeline at all. Instead:

  - Build pipelines run in tenant namespaces (e.g., team-foo-tenant) using per-component service accounts (build-pipeline-<component-name>)
  - The Tekton Chains controller runs in the openshift-pipelines (or tekton-chains) namespace as a cluster-scoped controller
  - Chains observes completed PipelineRuns/TaskRuns and then signs artifacts after the fact, from its own namespace
  - The signing key (signing-secrets Secret) lives in openshift-pipelines/tekton-chains namespace — never in the tenant namespace

  This means a compromised build pipeline cannot access the signing key, because the key simply isn't there.

  2. Per-component service accounts with least privilege

  Build Service creates build-pipeline-<component-name> service accounts (one per component), replacing an older shared appstudio-pipeline account. These SAs have:
  - Push credentials to the build-time OCI registry
  - No access to the signing key or the openshift-pipelines namespace

  3. Tenant vs Managed namespace separation for releases

  ┌──────────────────────────────┬────────────────────────────────────────────────────────────────────┬─────────────────────────┐
  │          Namespace           │                              Contains                              │     Who has access      │
  ├──────────────────────────────┼────────────────────────────────────────────────────────────────────┼─────────────────────────┤
  │ Tenant (user's)              │ Application, Component, build PipelineRuns, Snapshots, ReleasePlan │ User (admin)            │
  ├──────────────────────────────┼────────────────────────────────────────────────────────────────────┼─────────────────────────┤
  │ openshift-pipelines (system) │ Tekton Chains controller, signing-secrets, public-key              │ Platform operators only │
  ├──────────────────────────────┼────────────────────────────────────────────────────────────────────┼─────────────────────────┤
  │ Managed (release)            │ ReleasePlanAdmission, release credentials, release PipelineRuns    │ Release administrators  │
  └──────────────────────────────┴────────────────────────────────────────────────────────────────────┴─────────────────────────┘

  The security model in practice

  Tenant Namespace                    System Namespace (openshift-pipelines)
  ┌─────────────────────┐            ┌──────────────────────────┐
  │ Build PipelineRun   │            │ Tekton Chains Controller │
  │  (runs as build-    │──completes──>│  - watches PipelineRuns │
  │   pipeline-mycomp)  │            │  - signs artifacts       │
  │                     │            │  - generates attestations │
  │ NO signing keys     │            │                          │
  │ here                │            │ signing-secrets (cosign)  │
  │                     │            │ public-key (readable)     │
  └─────────────────────┘            └──────────────────────────┘
                                                │
                                       signs & attests
                                                │
                                                v
                                     ┌──────────────────┐
                                     │  OCI Registry     │
                                     │  image + .sig +   │
                                     │  .att (in-toto)   │
                                     └──────────────────┘

  Key insight for your CTF project

  In your current supply-chain-dd setup, Tekton Chains and the cosign signing key are deployed into the same cluster. The difference from Konflux's production model is:

  - Konflux: The signing-secrets is in openshift-pipelines, RBAC prevents tenant users from reading it, and Chains signs asynchronously as a controller
  - Your setup: You configure Chains in a similar way (tekton-chains namespace), but on a single-node KinD cluster the RBAC boundaries are the main enforcement
  mechanism

  This architecture means even if an attacker exfiltrates build credentials (like your Challenge 1 token theft), they still can't forge signatures because the signing
  key was never accessible from the build pipeline's namespace or service account.

  Sources:
  - [Konflux Pipeline Service Architecture](https://konflux-ci.dev/architecture/core/pipeline-service/)
  - [Konflux Architecture Overview](https://konflux-ci.dev/architecture/)
  - [Tekton Chains Signing Documentation](https://tekton.dev/docs/chains/signing/)
  - [Verifying Konflux Build Signatures with Cosign](https://conforma.dev/docs/user-guide/cosign.html)


# SBOMs in Konflux: Both Attached AND Attested (signed)

  Konflux pushes SBOMs in two forms, and this distinction matters for security:

  1. Raw SBOM attachment (unsigned)

  The SBOM is attached to the OCI image as a plain artifact (media type application/vnd.cyclonedx+json). You can download it with:

  cosign download sbom $IMAGE

  This is NOT signed. The Conforma/cosign docs explicitly warn: "cosign download sbom offers no guarantee that the SBOM attachment was produced as part of the Konflux 
  build pipeline. It is susceptible to modifications outside the build pipeline."

  2. SBOM as a signed in-toto attestation (signed)

  The SBOM is also embedded inside an in-toto attestation, which Tekton Chains signs with the cluster's cosign key. To get the tamper-proof version:

  cosign download attestation $IMAGE
  cosign verify-attestation --type slsaprovenance --key cosign.pub $IMAGE

  This attestation is cryptographically signed by Chains and stored in the OCI registry alongside the image. It includes the SLSA provenance predicate with the full
  build pipeline details.

  How the SBOM is generated

  Konflux uses a dual-generator approach inside the build pipeline:

  1. Cachi2 — generates SBOMs for prefetched/hermetic dependencies (gomod, npm, pip, etc.)
  2. Syft — scans the built container image for additional components

  These two SBOMs are merged into a single document during the build. Builder images are then added as build dependencies. The format is selectable via a pipeline
  parameter (sbomType: cyclonedx or sbomType: spdx).

  The trust chain

  Build Pipeline (tenant namespace)
    ├── cachi2 → dependency SBOM ─┐
    ├── syft   → image SBOM ──────┤
    └── merge ─────────────────────┘
             │
             v
      merged SBOM (CycloneDX or SPDX)
             │
             ├──→ attached as raw OCI artifact (UNSIGNED)
             │
             └──→ embedded in in-toto attestation
                       │
                       v
                Tekton Chains (system namespace)
                  signs attestation with cosign key
                       │
                       v
                OCI registry: image + .sig + .att
                       │
                       v
                Enterprise Contract / Conforma
                  verifies attestation at release time

  Key takeaway

  If you only cosign download sbom, you get an unverified artifact that could have been tampered with. The secure path is to use cosign verify-attestation to get the
  signed attestation containing the SBOM, or rely on Enterprise Contract / Conforma to validate it at release time. The signing happens via Tekton Chains in the system
  namespace — never in the build pipeline — so even a compromised build can't forge the attestation signature.

  Sources:
  - [Inspecting Artifact SBOMs — Konflux Documentation](https://konflux-ci.dev/docs/how-tos/metadata/sboms/)
  - [Using Cosign to Verify Konflux Build Signatures & Attestations — Conforma](https://conforma.dev/docs/user-guide/cosign.html)
  - [Konflux Mobster — SBOM Management Tooling](https://github.com/konflux-ci/mobster)
  - [ADR-0044: SPDX SBOM Support](https://konflux-ci.dev/architecture/ADR/0044-spdx-support/)
  - E[nabling Hermetic Builds — Konflux Documentation](https://konflux-ci.dev/docs/building/hermetic-builds/)
  - [How We Use Software Provenance at Red Hat](https://developers.redhat.com/articles/2025/05/15/how-we-use-software-provenance-red-hat)
  - [Reproducible Builds in Project Hummingbird](https://developers.redhat.com/articles/2026/03/26/reproducible-builds-project-hummingbird)


# How the SBOM Goes From Unsigned Blob to Signed Attestation

  Step 1: Build task generates the SBOM and pushes it as a raw blob

  During the build, the buildah-oci-ta task does three things:
  1. Builds the container image and pushes it to the OCI registry
  2. Generates the SBOM (via cachi2 + syft merge) in CycloneDX or SPDX format
  3. Pushes the raw SBOM as an unsigned OCI blob to the registry (using cosign attach sbom)

  At this point, the SBOM is just an attachment on the image — anyone with registry write access could replace it.

  Step 2: Build task emits type-hinted results

  This is the critical handoff mechanism. The buildah task declares specific result names that Tekton Chains knows how to interpret:

  ## From the buildah-oci-ta task spec
  results:
    - name: IMAGE_URL          # → Chains reads this as the artifact URI
    - name: IMAGE_DIGEST       # → Chains reads this as the artifact digest
    - name: SBOM_BLOB_URL      # → Reference to the SBOM blob in the registry
    - name: CHAINS-GIT_URL     # → Source repo URL (goes into materials)
    - name: CHAINS-GIT_COMMIT  # → Exact commit SHA (goes into materials)

  These results are written to the Kubernetes API as part of the TaskRun/PipelineRun status. The build task itself never touches any signing key — it just emits
  plain-text results.

  Step 3: Tekton Chains controller picks up the completed PipelineRun

  The Chains controller runs as a watch loop in the openshift-pipelines namespace. When it sees a PipelineRun transition to Succeeded:

  1. Snapshot: Chains takes an immutable snapshot of the PipelineRun status (all task results, parameters, timestamps)
  2. Deep inspection (artifacts.pipelinerun.enable-deep-inspection: true): Chains dives into each child TaskRun to read type-hinted results — not just pipeline-level
  results. This is how it finds SBOM_BLOB_URL, IMAGE_URL, etc. from individual tasks like buildah

  Step 4: Chains constructs the in-toto attestation

  Chains maps the type-hinted results into the in-toto attestation envelope:

  {
    "payloadType": "application/vnd.in-toto+json",
    "payload": "<base64 of Statement>",
    "signatures": [{ "sig": "<cosign signature>" }]
  }

  The Statement inside contains:

  {
    "_type": "https://in-toto.io/Statement/v1",
    "subject": [
      {
        "name": "pkg:/docker/registry.example.com/my-app",
        "digest": { "sha256": "abcd1234..." }
      }
    ],
    "predicateType": "https://slsa.dev/provenance/v0.2",
    "predicate": {
      "builder": { "id": "https://tekton.dev/chains/v2" },
      "buildType": "tekton.dev/v1beta1/PipelineRun",
      "invocation": {
        "parameters": { ... }
      },
      "buildConfig": {
        "tasks": [
          {
            "name": "buildah-oci-ta",
            "results": {
              "IMAGE_URL": "registry.example.com/my-app",
              "IMAGE_DIGEST": "sha256:abcd1234...",
              "SBOM_BLOB_URL": "registry.example.com/my-app@sha256:ef56..."
            }
          }
        ]
      },
      "materials": [
        {
          "uri": "https://github.com/org/repo",
          "digest": { "sha1": "abc123..." }
        }
      ]
    }
  }

  The key detail: SBOM_BLOB_URL is captured inside predicate.buildConfig.tasks[].results. This creates a cryptographic binding between the SBOM blob and the build — the
   signed attestation says "this exact SBOM blob (by digest) was produced by this exact build."

  Step 5: Chains signs and pushes the attestation

  Using the cosign key from signing-secrets in its own namespace:

  1. Signs the entire in-toto envelope
  2. Pushes the signed attestation to the OCI registry as an .att tag (via cosign triangulate convention)
  3. Also pushes the image signature as a .sig tag

  The complete picture

  Build Pipeline (tenant namespace)            Tekton Chains (system namespace)
  ┌──────────────────────────────┐
  │ buildah-oci-ta task          │
  │                              │
  │ 1. Build image ──push──────────→ registry: image@sha256:abcd
  │ 2. Generate SBOM (syft+cachi2)│
  │ 3. Push raw SBOM ─push────────→ registry: image SBOM attachment (UNSIGNED)
  │ 4. Emit results:             │
  │    IMAGE_URL = ...           │
  │    IMAGE_DIGEST = sha256:abcd│
  │    SBOM_BLOB_URL = ...@ef56  │
  │    CHAINS-GIT_URL = ...      │
  │    CHAINS-GIT_COMMIT = ...   │
  └──────────┬───────────────────┘
             │
             │  PipelineRun completes
             │  (results in K8s API)
             │
             ▼
    ┌────────────────────────────────────────┐
    │ Chains controller (watches PipelineRuns)│
    │                                        │
    │ 1. Snapshot PipelineRun status         │
    │ 2. Deep-inspect child TaskRun results  │
    │ 3. Map type hints → in-toto statement: │
    │    subject ← IMAGE_URL + IMAGE_DIGEST  │
    │    materials ← CHAINS-GIT_*            │
    │    buildConfig.results ← SBOM_BLOB_URL │
    │ 4. Sign with signing-secrets key       │
    │ 5. Push signed attestation (.att)  ──────→ registry: image .att (SIGNED)
    │    Push image signature (.sig)     ──────→ registry: image .sig (SIGNED)
    └────────────────────────────────────────┘

  Why this matters for verification

  - cosign download sbom → gets the raw blob from step 1 → unsigned, could be tampered
  - cosign verify-attestation → gets the signed envelope from step 5 → signed, contains the SBOM blob digest inside the attestation, so you can cross-check the raw SBOM
   against the attested digest
  - Enterprise Contract / Conforma → at release time, validates the signed attestation and checks that the SBOM blob digest matches what was attested — if someone
  swapped the SBOM after the build, the digests won't match

  The SBOM is never re-uploaded or transformed by Chains. Chains just records its digest inside the signed attestation. The trust comes from the fact that the Chains
  controller read the SBOM_BLOB_URL result at the moment the build completed, before anyone could tamper with it.

  Sources:
  - [Konflux build-definitions: docker-build-oci-ta pipeline](https://github.com/konflux-ci/build-definitions/blob/main/pipelines/docker-build-oci-ta/README.md)
  - [Tekton Chains SLSA Provenance — Type Hinting](https://tekton.dev/docs/chains/slsa-provenance/)
  - [Tekton Chains Configuration — Deep Inspection](https://tekton.dev/docs/chains/config/)
  - [Tekton Chains In-Toto Format (GitHub)](https://github.com/tektoncd/chains/blob/main/docs/intoto.md)
  - [Conforma: Verifying Konflux Attestations](https://conforma.dev/docs/user-guide/cosign.html)
  - [Red Hat OpenShift Pipelines: Securing Pipelines](https://docs.redhat.com/en/documentation/red_hat_openshift_pipelines/1.14/html-single/securing_openshift_pipelines/index)
