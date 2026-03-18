MAX=20
COUNT=0

while [ $COUNT -lt $MAX ]; do
  result=$(cat PROMPT.md | claude --print --dangerously-skip-permissions)
  echo "$result"
  COUNT=$((COUNT + 1))
  if echo "$result" | grep -q "COMPLETE"; then break; fi
done

if [ $COUNT -eq $MAX ]; then
  echo "⚠️  Hit max iterations ($MAX) without completing."
fi