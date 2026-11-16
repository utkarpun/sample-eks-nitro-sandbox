"""The one tool target behind the AgentCore Gateway: a read-only clock.

The gateway invokes this function for every tool call on the target and names the
tool in the client context, as `<target>___<tool>`. The function holds no state,
reads nothing outside itself and writes nothing, so a call it answers changes
nothing anywhere.

Two tools share the target on purpose. The Cedar policy on the gateway permits the
agent's role to call `get_time` only, so `get_host_info` exists to show a call the
policy refuses: the function would answer it, and the gateway never lets the call
reach the function.
"""

import datetime
import json
import os
import zoneinfo


def _tool_name(context):
    custom = getattr(getattr(context, "client_context", None), "custom", None) or {}
    name = custom.get("bedrockAgentCoreToolName", "")
    return name.split("___", 1)[-1]


def handler(event, context):
    tool = _tool_name(context)
    # One log line per call, naming the tool, so the function's log shows which
    # calls the gateway let through.
    print(json.dumps({"tool": tool}))
    if tool == "get_time":
        tz_name = (event or {}).get("timezone") or "UTC"
        try:
            tz = zoneinfo.ZoneInfo(tz_name)
        except (zoneinfo.ZoneInfoNotFoundError, ValueError):
            return {"error": f"unknown timezone: {tz_name}"}
        return {"timezone": tz_name, "time": datetime.datetime.now(tz).isoformat(timespec="seconds")}
    if tool == "get_host_info":
        return {
            "function": os.environ.get("AWS_LAMBDA_FUNCTION_NAME", ""),
            "region": os.environ.get("AWS_REGION", ""),
            "memory_mb": os.environ.get("AWS_LAMBDA_FUNCTION_MEMORY_SIZE", ""),
        }
    return {"error": f"unknown tool: {tool or '<none>'}"}
