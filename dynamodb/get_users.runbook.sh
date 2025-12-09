aws dynamodb scan \
    --table-name test-dynamodb-table \
    --region us-west-2 \
    --filter-expression "#t = :user_type AND user_id = :uid" \
    --expression-attribute-names '{"#t": "type"}' \
    --expression-attribute-values '{
      ":user_type": {"S": "USER"},
      ":uid": {"N": "{{ .user_id }}"}
    }'
