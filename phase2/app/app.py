from flask import Flask, jsonify, request
import os
import signal
import threading
import time

app = Flask(__name__)

# Track app state
app_state = {
    "healthy": True,
    "memory_hog": [],
    "start_time": time.time()
}

# ---- HEALTHY ENDPOINTS ----

@app.route("/")
def home():
    return jsonify({
        "service": "self-healing-demo",
        "phase": 2,
        "status": "running",
        "uptime_seconds": round(time.time() - app_state["start_time"], 1)
    })

@app.route("/health")
def health():
    """ALB will hit this endpoint every 30 seconds"""
    if app_state["healthy"]:
        return jsonify({"status": "healthy"}), 200
    else:
        return jsonify({"status": "unhealthy", "reason": "manually triggered"}), 500

# ---- FAILURE ENDPOINTS (for testing) ----

@app.route("/fail/crash")
def crash():
    """Simulate app crash - container exits with code 1"""
    def _crash():
        time.sleep(0.5)
        os.kill(1, signal.SIGKILL)
    threading.Thread(target=_crash).start()
    return jsonify({"action": "crashing in 0.5s"}), 200

@app.route("/fail/oom")
def oom():
    """Eat memory until OOM killer strikes (exit code 137)"""
    def _eat_memory():
        while True:
            # Allocate 10MB chunks
            app_state["memory_hog"].append("X" * 10 * 1024 * 1024)
            time.sleep(0.1)
    threading.Thread(target=_eat_memory).start()
    return jsonify({"action": "eating memory", "warning": "OOM kill incoming"}), 200

@app.route("/fail/health")
def fail_health():
    """Make health check return 500 - ALB will mark unhealthy"""
    app_state["healthy"] = False
    return jsonify({"action": "health check now returns 500"}), 200

@app.route("/fail/health/recover")
def recover_health():
    """Restore health check"""
    app_state["healthy"] = True
    return jsonify({"action": "health check restored to 200"}), 200

@app.route("/status")
def status():
    """Show current app state for debugging"""
    return jsonify({
        "healthy": app_state["healthy"],
        "memory_chunks_allocated": len(app_state["memory_hog"]),
        "memory_approx_mb": len(app_state["memory_hog"]) * 10,
        "uptime_seconds": round(time.time() - app_state["start_time"], 1),
        "pid": os.getpid()
    })

if __name__ == "__main__":
    app.run(host="0.0.0.0", port=5000)
