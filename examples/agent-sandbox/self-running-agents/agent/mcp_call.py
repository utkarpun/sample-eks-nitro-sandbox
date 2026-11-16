"""List the gateway's tools and call named ones, with no model in the loop.

Usage: mcp_call.py <mcp.json> [tool ...]

It talks to the gateway directly over MCP streamable HTTP, signing each request
with SigV4 as the pod's role, using the client library the agent's bridge is
built on. It does not go through the bridge, because the bridge only offers the
tools the gateway listed: a call to an unlisted tool would be refused by the
bridge itself and never reach the gateway, which is not what this checks.

Each named tool is called with an empty argument object except get_time, which
gets {"timezone": "UTC"}. The output is one JSON document: the tool names the
gateway lists for this role, and each call's error flag and text. The gateway
refuses a call the Cedar policy does not permit with a JSON-RPC error, recorded
here with rpcError true.
"""

import asyncio
import json
from datetime import timedelta
import os
import sys

from mcp import ClientSession
from mcp.shared.exceptions import McpError
from mcp_proxy_for_aws.client import aws_iam_streamablehttp_client


async def main(cfg_path, names):
    endpoint = json.load(open(cfg_path))["mcpServers"]["gateway"]["args"][0]
    out = {"endpoint_host": endpoint.split("/")[2], "listed": [], "calls": []}
    async with aws_iam_streamablehttp_client(
        endpoint, aws_service="bedrock-agentcore", aws_region=os.environ["AWS_REGION"]
    ) as (read, write, _):
        async with ClientSession(read, write, read_timeout_seconds=timedelta(seconds=60)) as session:
            await session.initialize()
            out["listed"] = sorted(t.name for t in (await session.list_tools()).tools)
            for name in names:
                args = {"timezone": "UTC"} if name.endswith("get_time") else {}
                try:
                    res = await session.call_tool(name, args)
                except McpError as e:
                    # The gateway refuses a call the policy does not permit with a
                    # JSON-RPC error, not a tool result.
                    out["calls"].append({"tool": name, "isError": True, "rpcError": True, "text": str(e)})
                    continue
                text = " ".join(getattr(c, "text", "") for c in res.content)
                out["calls"].append({"tool": name, "isError": bool(res.isError), "rpcError": False, "text": text})
    print(json.dumps(out, indent=2))


if __name__ == "__main__":
    asyncio.run(main(sys.argv[1], sys.argv[2:]))
