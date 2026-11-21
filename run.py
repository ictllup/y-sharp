#!/usr/bin/env python3
"""Local dev launcher for Y-Sharp: python run.py"""
import os

import uvicorn

if __name__ == "__main__":
    port = int(os.getenv("PORT", "8000"))
    print(f"\n  Y-Sharp  ->  http://localhost:{port}\n")
    uvicorn.run(
        "app.main:app",
        host="0.0.0.0",
        port=port,
        reload=bool(os.getenv("YSHARP_DEV")),
        proxy_headers=True,
        forwarded_allow_ips="*",
    )
