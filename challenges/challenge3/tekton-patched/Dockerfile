# Hardened multi-stage Dockerfile for recipe-api
# Both stages use the internal registry with digest-pinned references.
# The defense-demo.sh script replaces PLACEHOLDER digests at demo time.
FROM registry.registry.svc.cluster.local:5000/golang@sha256:PLACEHOLDER AS builder

WORKDIR /app
COPY go.mod ./
RUN go mod download || true
COPY . .
RUN CGO_ENABLED=0 GOOS=linux go build -o recipe-api main.go

FROM registry.registry.svc.cluster.local:5000/alpine@sha256:PLACEHOLDER

RUN apk --no-cache add ca-certificates
WORKDIR /app
COPY --from=builder /app/recipe-api .
EXPOSE 8080
CMD ["./recipe-api"]
