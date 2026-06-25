# Multi-stage build for Recipe API
#
# Stage 1 (builder): compile le binaire Go
# Stage 2 (runtime): copie le binaire compilé dans une image Alpine 

# Stage 1: Build
FROM registry.registry.svc.cluster.local:5000/golang:1.25-alpine AS builder
# Utilise le DNS interne au cluster (la pipeline accède directement à la registry)
WORKDIR /app

COPY go.mod ./
RUN go mod download || true

COPY . .
RUN CGO_ENABLED=0 GOOS=linux go build -o recipe-api main.go

# Stage 2: Runtime — contient le binaire uniquement, pas de source, ni .git, ni .env
FROM registry.registry.svc.cluster.local:5000/alpine:3.20
# Utilise le DNS interne au cluster (la pipeline accède directement à la registry)
RUN apk --no-cache add ca-certificates
WORKDIR /app
COPY --from=builder /app/recipe-api .

EXPOSE 8080
CMD ["./recipe-api"]
