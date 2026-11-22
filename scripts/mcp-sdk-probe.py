"""Connects to the app's MCP server with the official MCP Python SDK (the client Hermes uses) and prints a summary.
Usage: python -I mcp-sdk-probe.py http://127.0.0.1:PORT/mcp TOKEN   (run by hermes-checks when HERMES_MCP_PYTHON is set)
"""
import asyncio
import sys

import httpx
from mcp import ClientSession
from mcp.client.streamable_http import streamable_http_client


async def main(url: str, token: str) -> None:
    async with httpx.AsyncClient(headers={"Authorization": f"Bearer {token}"}) as http:
        async with streamable_http_client(url, http_client=http) as streams:
            read, write = streams[0], streams[1]
            async with ClientSession(read, write) as s:
                init = await s.initialize()
                tools = await s.list_tools()
                r = await s.call_tool("client_browser_navigate", {"url": "https://example.com"})
                text = r.content[0].text if r.content else ""
                print(f"OK version={getattr(init, "protocol_version", None) or getattr(init, "protocolVersion", None)} tools={len(tools.tools)} call={text!r} isError={getattr(r, "is_error", getattr(r, "isError", None))}")


asyncio.run(main(sys.argv[1], sys.argv[2]))
