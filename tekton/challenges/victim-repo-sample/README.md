# Awesome Project

A sample open-source project demonstrating Tekton Pipelines for CI/CD.

## Project Structure

```
.
├── README.md
├── scripts/
│   └── quality-check/
│       └── main.go          # Quality check script
└── .tekton/
    └── README.md            # CI/CD documentation
```

## Contributing

We welcome contributions! Please follow these guidelines:

1. Fork this repository
2. Create a feature branch
3. Make your changes
4. Submit a pull request

### Automated Quality Checks

All pull requests automatically trigger our quality check pipeline. The pipeline will:
- Clone your PR code
- Run formatting checks
- Run linting
- Verify code quality
- Post results as a comment on your PR

The pipeline typically completes in under 2 minutes.

## CI/CD Pipeline

This project uses **Tekton Pipelines** for continuous integration. Our CI system:

- Automatically runs on every pull request
- Checks code quality and formatting
- Runs security scans
- Provides feedback directly on your PR

### How It Works

When you open a PR, our Tekton EventListener receives a webhook from Git and:
1. Clones your fork at the PR commit SHA
2. Runs `scripts/quality-check/main.go` to validate code quality
3. Reports results back to the PR

**Note:** The quality check script runs automatically - you don't need to do anything special!

## Quality Check Script

Our quality checks are defined in `scripts/quality-check/main.go`. This script:
- Validates Go code formatting
- Checks for common issues
- Ensures README exists
- Verifies project structure

You can run the quality checks locally:
```bash
cd scripts/quality-check
go run .
```

## License

MIT License - see LICENSE file for details

## Security

If you discover any security issues, please email security@awesome-project.example (this is a CTF demo - not a real address).

---

Built with ❤️ by the Awesome Project team
