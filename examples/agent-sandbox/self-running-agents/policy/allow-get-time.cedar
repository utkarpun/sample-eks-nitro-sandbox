// The one permit on the gateway. Cedar is default-deny and forbid-wins, so the
// agent's role may call clock___get_time and nothing else, and no other caller
// may call anything.
permit (
  principal == AgentCore::IamEntity::"arn:aws:sts::<ACCOUNT_ID>:assumed-role/<AGENT_ROLE_NAME>",
  action == AgentCore::Action::"clock___get_time",
  resource == AgentCore::Gateway::"<GATEWAY_ARN>"
);
