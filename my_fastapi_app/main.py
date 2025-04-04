from fastapi import FastAPI
from fastapi.responses import HTMLResponse
from azure.monitor.opentelemetry import configure_azure_monitor
from opentelemetry import trace
from opentelemetry.propagate import inject
from opentelemetry.instrumentation.fastapi import FastAPIInstrumentor
from opentelemetry.instrumentation.httpx import HTTPXClientInstrumentor

import httpx
import os
import logging

import asyncio
import time

# Set up logging
logging.basicConfig(
    format="%(asctime)s,%(msecs)d %(name)s %(levelname)s %(message)s",
    datefmt="%H:%M:%S",
    level=logging.INFO,
)
# Supress logging from Azure Monitor and OpenTelemetry:
logging.getLogger("azure.core.pipeline").setLevel(logging.WARNING)
logging.getLogger("azure.monitor.opentelemetry").setLevel(logging.WARNING)

logger = logging.getLogger("myfastapiapp")
app = FastAPI()

if "APPLICATIONINSIGHTS_CONNECTION_STRING" in os.environ:
    if "OTEL_SERVICE_NAME" not in os.environ:
        os.environ["OTEL_SERVICE_NAME"] = os.environ.get(
            "CONTAINER_APP_NAME", "my-fastapiapp-localhost"
        )
    # Configure the Azure Monitor exporter
    configure_azure_monitor(logger_name="myfastapiapp", enable_live_metrics=True)
    # Configure the OpenTelemetry SDK
    FastAPIInstrumentor.instrument_app(app, excluded_urls="/health")
    HTTPXClientInstrumentor().instrument()

tracer = trace.get_tracer("myfastapiapp")

# When running in ContainerApp, there are actually 3 containers running (of the same image)
# When running locally, there is only localhost 8000 (default port)
TARGET_SELF = os.environ.get("LOCALHOST", "localhost:8000")
TARGET_B_HOST = os.environ.get("TARGET_B_HOST", TARGET_SELF)
TARGET_C_HOST = os.environ.get("TARGET_C_HOST", TARGET_SELF)


@app.get("/", response_class=HTMLResponse)
async def read_root():
    logger.info("This is an INFO logging (before the SPAN).")
    with tracer.start_as_current_span("read_root"):
        logger.debug("Is debug also logged, since loglevel is set to INFO?")
        logger.info("This is an INFO logging (inside the span).")
        return f"""
        <html>
            <head>
                <title>Demo FastAPI</title>
            </head>
            <body>
                <h1>My FastAPI App</h1>
                <p>Hello World! - Running in Azure Container Apps: {os.environ.get('CONTAINER_APP_NAME', 'no-container-app')}</p>
                <p>You should have a look in Azure Application Insights to see the traces of these clicks!</p>
                <ul><b>Endpoints:</b>
                    <li><a href="/io_task">IO Task (10 sec)</a></li>
                    <li><a href="/cpu_task">CPU Task (calc 1000 ^ 3)</a></li>
                    <li><a href="/exception">Exception</a></li>
                    <li><a href="/chain">Chain concurrent requests</a></li>
                    <li><a href="/health">Health check</a></li>
                </ul>
                </body>
        </html>"""


@app.get("/io_task")
async def io_task():
    logger.debug("io task, start waiting for 10 sec...")
    await asyncio.sleep(10)
    logger.info("io task")
    return "IO bound task finish!"


@app.get("/cpu_task")
async def cpu_task():
    with tracer.start_as_current_span("cpu_task"):
        logger.info("cpu task")
        for i in range(1000):
            _ = i * i * i
    return "CPU bound task finish!"


@app.get("/exception")
async def exception():
    with tracer.start_as_current_span("trace_exception") as span:
        logger.warning("This is a warning, just before it breaks...")
        span.set_attribute("MyCustomAttr", "We are going down!")
        raise ValueError("there was a problem.")


@app.get("/chain")
async def chain(exception: bool = False):
    headers = {}

    # Forward the tracing headers to the downstream services
    inject(headers)  # inject trace info to header
    logger.info("Chain passes these headers", headers)

    # Track time for logging as extra properties
    start = time.perf_counter()

    # Reuse the client with the same headers and timeout
    async with httpx.AsyncClient(headers=headers, timeout=15) as client:
        logger.info("Start 3 calls at the same time...")

        # If exception is set, add a failing call to the chain
        # Create a list of tasks to call the endpoints
        tasks = [
            client.get(f"http://{TARGET_SELF}/", timeout=3),
            client.get(f"http://{TARGET_B_HOST}/io_task"),
            client.get(f"http://{TARGET_C_HOST}/cpu_task"),
            client.get(f"http://{TARGET_C_HOST}/io_task"),
        ]

        # If exception is set, add the exception endpoint to the tasks.
        if exception:
            tasks.append(client.get(f"http://{TARGET_SELF}/exception", timeout=3))

        # Execute all tasks in parallel
        responses: list[Exception | httpx.Response] = await asyncio.gather(*tasks, return_exceptions=True)

    # Auto closing the client (using the context manager)

    # Build a nice summary for the response
    api_call_summary = {}
    for idx, returned in enumerate(responses):
        if isinstance(returned, Exception):
            logger.error(f"Request failed with exception: {returned}")
            api_call_summary[f"response_{idx}"] = {"error": str(returned)}
        else:
            logger.info(f"Request completed with status code: {returned.status_code}")
            api_call_summary[f"response_{idx}"] = {
                "status_code": returned.status_code,
                "body": returned.text[:40],
            }

    total_time = time.perf_counter() - start
    logger.info(f"Chain Finished in {total_time:.2f} seconds")

    returned = {
        "path": "/chain",
        "total_time": f"{total_time:.2f}",
        "api_call_summary": api_call_summary
    }
    if exception:
        returned["hint"] = "pass ?exception=true to add a failing call in the chain."
    return returned


@app.get("/health")
async def healthcheck():
    return {"status": "ok"}
