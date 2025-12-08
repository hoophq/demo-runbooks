aws dynamodb scan \
    --table-name test-dynamodb-table \
    --region us-west-2 \
    --filter-expression "#t = :payment_type AND user_id = :uid" \
    --expression-attribute-names '{"#t": "type"}' \
    --expression-attribute-values '{
      ":payment_type": {"S": "PAYMENT"},
      ":uid": {"N": "{{ .user_id }}"}
    }'
