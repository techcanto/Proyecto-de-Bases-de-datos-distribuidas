import os

from flask import Flask, send_from_directory
from flask_cors import CORS

from routes.clientes import bp_clientes
from routes.diagnostico import bp_diagnostico
from routes.direcciones import bp_direcciones
from routes.tablas import bp_tablas
from routes.tailscale import bp_tailscale

FRONTEND_DIR = os.path.join(os.path.dirname(__file__), "..", "frontend")

app = Flask(__name__, static_folder=FRONTEND_DIR, static_url_path="/static")
CORS(app)

app.register_blueprint(bp_clientes)
app.register_blueprint(bp_diagnostico)
app.register_blueprint(bp_direcciones)
app.register_blueprint(bp_tablas)
app.register_blueprint(bp_tailscale)


@app.route("/")
def index():
    return send_from_directory(FRONTEND_DIR, "index.html")


@app.route("/<path:filename>")
def frontend_files(filename):
    return send_from_directory(FRONTEND_DIR, filename)


if __name__ == "__main__":
    import sys
    # When running without a TTY (nohup/background), turn off debug mode
    # so the reloader does not fork — which would orphan the server child.
    debug = sys.stdout.isatty()
    app.run(debug=debug, host="0.0.0.0", port=5000)
