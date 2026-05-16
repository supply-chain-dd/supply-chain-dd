# Multi-stage build for Recipe API
#
# Stage 1 (builder): compiles the Go binary — may contain .git, .env, source code
# Stage 2 (runtime): copies only the compiled binary into a minimal Alpine image
#
# Combined with .dockerignore (allowlist pattern), .git and .env never enter
# the build context at all. Even without .dockerignore, the multi-stage build
# ensures they never appear in the pushed image.

# Stage 1: Build
FROM registry.registry.svc.cluster.local:5000/golang:1.25-alpine AS builder
WORKDIR /app

COPY go.mod ./
RUN go mod download || true

COPY . .
RUN CGO_ENABLED=0 GOOS=linux go build -o recipe-api main.go

# Stage 2: Runtime — only the binary, no source, no .git, no .env
FROM alpine:3.20
RUN apk --no-cache add ca-certificates
WORKDIR /app
COPY --from=builder /app/recipe-api .

EXPOSE 8080
CMD ["./recipe-api"]
