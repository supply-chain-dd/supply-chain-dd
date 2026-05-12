# References

## on supply chain security
* [SLSA L3 E2E] https://github.com/arewm/slsa-konflux-example/blob/main/blog-draft-slsa-e2e-with-konflux.md
* [AMPEL](https://slsa.dev/blog/2025/10/slsa-e2e-with-ampel)
* [conforma](https://conforma.dev/docs/user-guide/)
* https://slides.arewm.com/presentations/2026-03-23-from-mild-to-wild/ 
* https://slides.arewm.com/presentations/2026-02-19-the-1-2-step/ 
* [Tekton Chains](https://tekton.dev/docs/chains/)
* [💕 Ozzie & Nova - Supply Chain Shenanigans: A Kubernetes Security Play Ab... Whitney Lee & Puja Abbassi](https://www.youtube.com/watch?v=pvEIH3R_8Dg)
* [Look at Tailscale](https://tailscale.com/)
* https://GitHub.com/snyk-labs/kubernetes-goof 
* [Who Wants To Secure Clusters ? - Henrik Rexed & Simon Reisinger, Dynatrace](https://youtu.be/8UXgIHSh8K0) 
* https://adnanthekhan.com/2024/05/06/the-monsters-in-your-build-cache-github-actions-cache-poisoning/ 
* https://docs.google.com/document/d/1dxxVJ2oLtdC-KfBxndV0iqbQ7cZ9jam4_X9g9BectXE/edit?tab=t.0 
* [Kubescape](https://kubescape.io/docs/)
* [Guac](https://docs.guac.sh/)
* https://getplumber.io/ 
* [CI Dependencies Recipe Card](https://docs.google.com/document/d/1o0uFWeBvzLeUYan0WAhP9uwUpb4DV-Ly6uglfhV54MQ/edit?tab=t.gotzv9t6hs9l#heading=h.mcjcpknnnmn)
* https://github.blog/news-insights/product-news/whats-coming-to-our-github-actions-2026-security-roadmap/ 

* De l’IA dans tout ça : Mytho! 😂 https://www.redhat.com/en/blog/navigating-mythos-haunted-world-platform-security?sc_cid=701f2000000txokAAA&utm_source=bambu&utm_medium=organic_social 

## on CTF preparation

* https://www.skybound.link/2025/11/kubecon-na-2025-ctf-writeup/ 
* https://blog.martino.wtf/posts/kubecon-in-25-ctf/ 
* https://hackrocks.com/blog/tips-and-tactics-for-creating-your-own-capture-the-flag-ctf 
* [KCD Denmark 2024: KubeCapture: Audience Driven Capture the Flag Session - Jonas Felix A real CTF of the supply chain attack](https://www.youtube.com/watch?v=wiP6hvRKNDg)

## on Kubernetes security

* Falco
* [Audicia](https://audicia.io)
* [Kyverno](https://kyverno.io/docs/introduction/)
* https://github.com/raesene/kube_security_lab/blob/main/Scenario%20Walkthroughs/rwkubelet-new.md 
* https://owasp.org/www-project-kubernetes-top-ten/
* https://raesene.github.io/blog/2025/09/12/beyond-the-surface/ ([Beyond the Surface: Exploring Attacker Persistence Strategies in Kubernetes - Rory McCune](https://www.youtube.com/watch?v=GtrkIuq5T3M&t=11s) )

## on existing attacks

* https://www.stepsecurity.io/blog/hackerbot-claw-github-actions-exploitation#attack-1-avelinoawesome-go---token-theft-via-poisoned-go-script
* [+ attaque Trivy du 19Mars](https://github.com/aquasecurity/trivy/security/advisories/GHSA-69fq-xp46-6x23) 
* https://next.ink/227265/hackerbot-claw-un-bot-exploite-github-actions-et-vide-le-depot-de-trivy/ + https://github.com/aquasecurity/trivy/pull/10417
* Compromised CI/CD environment
  * During dev
  * During distribution (build of container)
    * Compliance: kubebench, kubelinter, kubescape, kubesec 
  * During deployment 
* Base image selection: reduce your footprint. 30% of official looking images on DockerHub contain at least one high severity vulnerability
  * Having a vulnerability allow for reverse shell into a pod running that container
  * Then, we can do something similar to https://www.youtube.com/watch?v=iD_klswHJQs  (revshells.com, https://tryhackme.com/room/insekube ) listener can be nc, but also pwncat-cs
    * Be careful of containers that have root access
    * Be careful of service accounts having too much rbac access
    * https://bishopfox.com/blog/kubernetes-pod-privilege-escalation 
* MultiStage build contamination: malicious library added in the build image, then with a COPY -–from, the library goes undetected into the application image
  * https://medium.com/@instatunnel/the-danger-in-your-dockerfile-how-a-single-copy-can-compromise-your-container-5af4b818de07 
* .env to the CICD systems added in images pushed to public registries: https://trufflesecurity.com/blog/how-secrets-leak-out-of-docker-images 
  * Beware of ENV, ARG and COPY . , especially when repository contains .git
    * Even if .gitignore leaves .git out, COPY . doesn’t use that
    * A secret added to a commit (even if commit is reverted) can still be found through git history
  * -–build-arg is not good to pass secrets: manifest will still contain this in the config layer
  * Common example is CODECOV 2021 breach : https://about.codecov.io/security-update/ 
  * Use .dockerignore
  * Use multistage builds with mounting secrets into image using 
    * Use buildkit mount
    * Use podman build –secret
  * A caveat of this is when this secret is used to authenticate and then is saved into the image (~/.npmrc , .docker/config.json for examples)
* https://flare.io/learn/resources/docker-hub-secrets-exposed/ (ou bien, c’est pas parce que tu fais un rm -r .env dans le dockerfile que les secrets n’y sont plus!)
  * Oups ! the certificate for the TLS connection on production is leaked! How do we fix it?
  * Oups the private key for signing my image in the CI is leaked, how is this affecting all images signed with that key?
  * [The Shai-Hulud 2.0 NPM Worm](https://www.wiz.io/blog/shai-hulud-2-0-aftermath-ongoing-supply-chain-attack)
  * [tj-actions/changed-files](https://www.aquasec.com/blog/github-action-tj-actions-changed-files-compromised/) Supply Chain Breach: print CICD secrets (registry tokens, keys) to workflow logs
  * Argo CD (CVE-2022-24348)
* Dependency confusion
* Trojan image (base image containing malware)
* Vulnerability of deployment tooling (Argo, Helm)
* Secrets management?
  * External Secrets Operator / SOPS : none provides good security
    * ESO: puts the secret back into a kubernetes secret
    * SOPS:puts the secret in Kubernetes again, and stores the public key in a kubernetes secret too!
