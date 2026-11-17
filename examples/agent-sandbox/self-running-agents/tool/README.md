# tool: the one tool behind the gateway

`handler.py` is a small, read-only clock. It is the Lambda function `sra-clock` behind the
gateway's target `clock` ([`kro/AGENTCORE.md`](../kro/AGENTCORE.md)). It holds no state,
reads nothing outside itself and writes nothing, so a call it answers changes nothing.

| Tool | What it returns |
|---|---|
| `get_time` | The current time in an IANA time zone (`timezone`, such as `UTC`) |
| `get_host_info` | The function's own name, Region and memory size |

Two tools share the target on purpose. The Cedar policy lets the agent call `get_time`
only, so `get_host_info` is there to show a call the policy refuses: the function would
answer it, and the gateway never lets it through.

The gateway names the tool in the call's client context as `<target>___<tool>`. The function
prints one log line per call naming the tool, so its log shows which calls the gateway let
through (`test.sh` reads it).

## How it gets deployed

`setup.sh` zips `handler.py`, uploads it to the run bucket as `tool/clock-<hash>.zip`, then
applies the `SraGateway` instance, whose `tool` resource makes the function from that zip:
handler `handler.handler`, 10 s timeout, 128 MB. Its role is `sra-tool`
and its log group `/aws/lambda/sra-clock` keeps one day.

To change the tool, edit `handler.py` and run `setup.sh`: a new zip has a new key and hash,
and ACK updates the function's code.
