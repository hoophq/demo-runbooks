aws secretsmanager create-secret \
  --name {{ .secret_name }} \
  --secret-string '{ "{{ .secret_key | required "true" }}" : "{{ .secret_value | required "true"}}" }'
