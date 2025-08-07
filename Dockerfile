FROM golang:1.23-alpine AS builder
WORKDIR /app
# Force cache bust to ensure latest files are copied
COPY . .
RUN go mod init github.com/your-org/verifier || true
RUN go mod tidy
RUN go build -o verifier .

FROM alpine:latest
WORKDIR /app
COPY --from=builder /app/verifier .
CMD ["./verifier"]

# Force cache bust by adding a dummy build argument
ARG CACHE_BUST=1
