# CMF (Confluent Manager for Apache Flink)

Each cluster's `cmf-operator` Application (sync wave 118) installs the CMF Helm chart with [`base/values.yaml`](base/values.yaml) plus its `overlays/<cluster>/values.yaml`. Each cluster's `cmf-operator-secrets` Application (wave 117) syncs the Kustomize side of `overlays/<cluster>/`: the Secrets and PostgreSQL that CMF needs on the RBAC clusters, and on every cluster the [`sql-assistant-key`](components/sql-assistant-key/) component.

## SQL Assistant API key

CMF's SQL Assistant is on for every cluster. It uses Gemini, through model entry `gemini-flash` in [`base/values.yaml`](base/values.yaml). CMF reads the API key once, at startup, from:

| Secret | Key | Namespace | Placeholder value |
|---|---|---|---|
| `cmf-sql-assistant-llm` | `api-key` | `operator` | `not-configured` |

The key is set by hand, so it stays out of Git, Secrets Manager and Terraform state ([ADR-0024](../../adrs/0024-cmf-sql-assistant-placeholder-key-secret.md)). CMF does not start while the Secret or its key is missing. So the `cmf-sql-assistant-key` Job in `cmf-operator-secrets` creates the Secret with the placeholder whenever it is absent, and never touches an existing one.

Without a real key, the SQL Assistant tab answers with an invalid-key error, and SQL mode still runs statements. Turning the assistant on or off needs no Git change: replace the value, then restart CMF.

These commands are zsh. With the placeholder, the state check reports 14 bytes; with a real Gemini key, 39.

```zsh
# Pick the cluster's kube context: kind clusters are kind-<cluster>
CTX=kind-flink-demo
# eks-demo instead: start the SOCKS5 tunnel (clusters/eks-demo/README.md), then
#   export HTTPS_PROXY=socks5://localhost:1080; CTX=$(kubectl config get-contexts -o name | grep eks-demo)

# 1. Read the key without echo or history
read -rs 'GEMINI_API_KEY?Gemini API key: '; print

# 2. Check the key and list Flash models (header from stdin, so the key is not in curl's argv)
printf 'x-goog-api-key: %s\n' "$GEMINI_API_KEY" \
  | env -u HTTPS_PROXY -u https_proxy curl -sS -H @- \
      'https://generativelanguage.googleapis.com/v1beta/models?pageSize=1000' \
  | jq -r 'if .error then "\(.error.status) \([.error.details[]?.reason // empty] | join(",")): \(.error.message)\n" | halt_error(1)
           else .models[] | select((.name | test("flash"; "i")) and (.supportedGenerationMethods | index("generateContent")))
             | [(.name | ltrimstr("models/")), .displayName, (.inputTokenLimit | tostring)] | @tsv end'

# 3. Turn on, or rotate: replace the Secret in place; never `kubectl apply`
printf '%s' "$GEMINI_API_KEY" \
  | kubectl create secret generic cmf-sql-assistant-llm --namespace operator \
      --from-file=api-key=/dev/stdin --dry-run=client -o yaml \
  | kubectl --context "$CTX" replace -f -
unset GEMINI_API_KEY

# 4. State check without printing the value: 39 bytes = real key, 14 = placeholder
kubectl --context "$CTX" get secret cmf-sql-assistant-llm -n operator -o json \
  | jq '{keys: (.data | keys), bytes: (.data["api-key"] | @base64d | length), created: .metadata.creationTimestamp}'

# 5. After any switch: restart CMF (Recreate strategy: a brief CMF outage) and confirm it loaded the model
kubectl --context "$CTX" rollout restart deployment/confluent-manager-for-apache-flink -n operator
kubectl --context "$CTX" rollout status deployment/confluent-manager-for-apache-flink -n operator --timeout=5m
kubectl --context "$CTX" logs deployment/confluent-manager-for-apache-flink -n operator -c cmf | grep -F 'SQL Assistant'
```

- **Step 2** must list models. `INVALID_ARGUMENT API_KEY_INVALID` means the key is wrong: don't store it, and `unset GEMINI_API_KEY`. If the model in `base/values.yaml` isn't listed, the key's project can't use it.
- **Step 5** logs `SQL Assistant using model 'gemini-3.8-flash' (provider GOOGLE_GENAI, registry entry 'gemini-flash').` with a real key and with the placeholder alike: CMF doesn't check the key until the first request. A key replaced without a restart isn't used until CMF restarts.
- **To turn the assistant off,** put the placeholder back, then run steps 4 and 5:

  ```zsh
  kubectl create secret generic cmf-sql-assistant-llm --namespace operator \
      --from-literal=api-key=not-configured --dry-run=client -o yaml \
    | kubectl --context "$CTX" replace -f -
  ```

- **Never delete the Secret to turn the assistant off.** CMF does not start without it until the next `cmf-operator-secrets` sync re-creates the placeholder.
- **Never create it with `kubectl apply`.** That stores the value in the `last-applied-configuration` annotation.
- **What deletes the Secret:** deleting the `operator` Namespace, the `namespaces` Application or the `bootstrap` Application with cascade, or deleting the cluster. Argo CD never prunes it, because it carries no Argo tracking label or annotation. The next sync of `cmf-operator-secrets` re-creates the placeholder: a fresh bootstrap syncs it, but after a recreated Namespace, sync it by hand (it doesn't self-heal). Then run steps 1-5 to turn the assistant on again.
- **Each cluster has its own Secret.** Set the key on every cluster that should have the assistant on.

### Troubleshooting

- **CMF crash-loops with `Secret 'cmf-sql-assistant-llm' ... not found`:** the Secret was deleted. Sync `cmf-operator-secrets` to re-create the placeholder.
- **The SQL Assistant answers with an invalid API key error:** the placeholder is in place, or the key is wrong. Turn the assistant on with steps 1-5.
