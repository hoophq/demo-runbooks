  #!/bin/bash
  REGION="us-west-2"
  TABLE_NAME="test-dynamodb-table"
  USER_ID="{{ .user_id }}"
  NEW_EMAIL="{{ .email }}"

  # Step 1: Find partition key
  PARTITION_KEY=$(aws dynamodb scan \
      --table-name $TABLE_NAME \
      --region $REGION \
      --filter-expression "#t = :user_type AND user_id = :uid" \
      --expression-attribute-names '{"#t": "type"}' \
      --expression-attribute-values "{
        \":user_type\": {\"S\": \"USER\"},
        \":uid\": {\"N\": \"$USER_ID\"}
      }" \
      --query 'Items[0].id.S' \
      --output text)

  if [ -z "$PARTITION_KEY" ] || [ "$PARTITION_KEY" == "None" ]; then
      echo "Error: User not found"
      exit 1
  fi

  # Step 2: Update email
  aws dynamodb update-item \
      --table-name $TABLE_NAME \
      --region $REGION \
      --key "{\"id\": {\"S\": \"$PARTITION_KEY\"}}" \
      --update-expression "SET email = :new_email" \
      --expression-attribute-values "{\":new_email\": {\"S\": \"$NEW_EMAIL\"}}" \
      --return-values ALL_NEW \
      --output table

  echo "Email updated for user_id $USER_ID"
