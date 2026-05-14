# METADATA
# title: COPY copies .git directory into image layer
# description: |
#   Detects Dockerfiles that copy the entire build context (COPY . .) which
#   includes the .git directory. Even if .git is deleted in a subsequent RUN
#   layer, the data remains in the COPY layer and can be extracted by anyone
#   with image pull access. Use a .dockerignore allowlist or multi-stage
#   builds to prevent secrets in git history from leaking into images.
# schemas:
#   - input: schema["dockerfile"]
# related_resources:
#   - https://docs.docker.com/build/building/best-practices/#dockerignore
# custom:
#   id: DS-0100
#   long_id: docker-copy-git-leak
#   aliases:
#     - DS100
#     - copy-git-leak
#     - docker-copy-git-leak
#   severity: CRITICAL
#   recommended_action: >
#     Add a .dockerignore file with an allowlist pattern (ignore everything,
#     include only needed files) or use a multi-stage build that copies only
#     the compiled binary into the final image.
#   input:
#     selector:
#       - type: dockerfile
package user.dockerfile.DS100

import rego.v1

import data.lib.docker

copies_entire_context(cmd) if {
	cmd.Cmd == "copy"
	some i, src in cmd.Value
	i < count(cmd.Value) - 1
	src == "."
}

deletes_git_dir(cmd) if {
	cmd.Cmd == "run"
	some val in cmd.Value
	contains(val, "rm ")
	contains(val, ".git")
}

deny contains res if {
	some cmd in docker.copy
	copies_entire_context(cmd)
	msg := "COPY copies entire build context (including .git) into image layer. Secrets in git history will persist in this layer even if deleted later. Use a .dockerignore allowlist or multi-stage build."
	res := result.new(msg, cmd)
}

deny contains res if {
	some cmd in docker.run
	deletes_git_dir(cmd)
	msg := "RUN deletes .git but the data remains in the earlier COPY layer. Docker layers are immutable — 'rm -rf .git' only creates a whiteout marker in a new layer. Use .dockerignore to prevent .git from entering the build context."
	res := result.new(msg, cmd)
}
