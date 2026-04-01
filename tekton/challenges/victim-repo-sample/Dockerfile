# Single-stage build for Recipe API
# VULNERABILITY: This Dockerfile copies .git directory and then deletes it,
# but the .git content remains in the previous layer and can be extracted!
#
# This is a common mistake when developers try to "clean up" sensitive files
# after copying them, not realizing that Docker layers are immutable.

FROM golang:1.25-alpine

WORKDIR /app

# Copy go module files
COPY go.mod ./

# Download dependencies
RUN go mod download || true

# VULNERABILITY STEP 1: Copy everything including .git directory
# This creates a layer with .git content embedded
COPY . .

# Build the application
RUN CGO_ENABLED=0 GOOS=linux go build -o recipe-api main.go

# VULNERABILITY STEP 2: Attempting to remove .git directory
# SECURITY MISTAKE: This only creates a "whiteout" in a NEW layer!
# The actual .git content is still accessible in the previous COPY layer!
RUN rm -rf .git && \
    rm -rf .env* && \
    echo "Cleaned up sensitive files"

# Runtime setup
RUN apk --no-cache add ca-certificates

EXPOSE 8080

CMD ["./recipe-api"]
