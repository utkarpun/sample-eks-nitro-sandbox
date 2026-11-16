# The agent image: headless Claude Code and the SigV4 bridge it reaches the
# AgentCore Gateway through. One image runs every mode of agent/run.sh.
FROM public.ecr.aws/docker/library/node:22-bookworm-slim

# Pinned so a rebuild gets the versions this sample was checked against.
ARG CLAUDE_CODE_VERSION=2.1.310
# The bridge between an MCP client that speaks stdio and a remote MCP endpoint
# that needs SigV4. The -cli distribution pins its whole dependency tree.
ARG MCP_PROXY_FOR_AWS_CLI_VERSION=1.8.0

RUN apt-get update \
  && apt-get install -y --no-install-recommends ca-certificates python3 python3-venv \
  && rm -rf /var/lib/apt/lists/*

RUN npm install -g "@anthropic-ai/claude-code@${CLAUDE_CODE_VERSION}"

# A venv of its own, so boto3 (which run.sh uses to store the run's output) and
# the MCP client library (which agent/mcp_call.py uses) come from the bridge's
# pinned tree.
RUN python3 -m venv /opt/mcp \
  && /opt/mcp/bin/pip install --no-cache-dir "mcp-proxy-for-aws-cli==${MCP_PROXY_FOR_AWS_CLI_VERSION}" \
  && /opt/mcp/bin/python -c "import boto3, mcp, mcp_proxy_for_aws.client" \
  && test -x /opt/mcp/bin/mcp-proxy-for-aws-cli

# The agent's configuration, baked in, so the image decides which tools the
# agent holds: settings.json denies every built-in tool and allows only the
# gateway's. The gateway's address is not baked in: it comes from the run's
# ConfigMap (deploy/run-job.yaml), because it is known only after setup.
COPY agent/settings.json agent/claude.json agent/mcp_call.py agent/run.sh /opt/agent/
RUN chmod 0755 /opt/agent/run.sh

# The node user (uid 1000) that the base image ships.
USER node
WORKDIR /work
ENV HOME=/home/node
ENTRYPOINT ["/opt/agent/run.sh"]
