# This script is intended to act as a simple host for serving this plugin to a local Unraid system.
#
# Requirements:
#   - Python 3
#   - ServeStatic (install with `pip install servestatic`)
#   - An ASGI webserver (e.g. uvicorn, install with `pip install uvicorn`)

from pathlib import Path

from servestatic import ServeStaticASGI

app = ServeStaticASGI(None, root=Path(__file__).parent.parent, autorefresh=True)

# To run the server, execute the following command in the terminal:
# cd scripts && uvicorn webserver:app --host
#
# Now, you can install "http://<server_ip>:<port>/power.optimizer-local.plg" as a plugin within Unraid and it will pull the supporting files from this server.
