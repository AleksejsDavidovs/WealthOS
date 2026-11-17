"""Cloudflare Worker entry point for the WealthOS banking backend.

The FastAPI app is the same code as the local server (`backend/app`, linked as src/app); only
storage (D1), JWT signing (WebCrypto) and configuration (Worker bindings) differ. See
backend/cloudflare/README.md.
"""
from workers import asgi

from app.cloudflare import WorkerApp

Default = asgi.entrypoint(WorkerApp())
