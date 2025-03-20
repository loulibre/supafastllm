from fastapi import FastAPI, HTTPException, Depends, Header, Request, Response
from fastapi.staticfiles import StaticFiles
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import RedirectResponse, JSONResponse, HTMLResponse
from typing import Optional
import os
from jose import jwt, JWTError
from fastapi.security import HTTPBearer, HTTPAuthorizationCredentials
from pathlib import Path
import sys

app = FastAPI(title="SupaFast API")

# Get JWT secret from environment
JWT_SECRET = os.getenv("JWT_SECRET")
if not JWT_SECRET:
    raise ValueError("JWT_SECRET environment variable is required")

# Get anon key from environment
ANON_KEY = os.getenv("SUPABASE_ANON_KEY")
if not ANON_KEY:
    raise ValueError("SUPABASE_ANON_KEY environment variable is required")

# CORS configuration
app.add_middleware(
    CORSMiddleware,
    allow_origins=[
        "https://apps.topaims.net",
        "http://localhost:8000",
    ],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

# Security
security = HTTPBearer()

async def verify_jwt(credentials: HTTPAuthorizationCredentials = Depends(security)):
    try:
        token = credentials.credentials
        # Use the same JWT secret as other Supabase services
        payload = jwt.decode(
            token,
            JWT_SECRET,
            algorithms=['HS256']
        )
        return payload
    except JWTError:
        raise HTTPException(
            status_code=401,
            detail="Invalid authentication token"
        )

# Public routes (login, health check)
@app.get("/api/v1/health")
async def health_check():
    return {"status": "healthy"}

@app.get("/", response_class=HTMLResponse)
async def root():
    with open("public/index.html", "r") as f:
        html_content = f.read()
        # Insert the anon key into the HTML
        html_content = html_content.replace(
            'content=""',  # Look for empty content in meta tag
            f'content="{ANON_KEY}"'  # Replace with actual ANON_KEY
        )
        return HTMLResponse(content=html_content)

# Protected routes that require JWT
@app.get("/api/v1/protected")
async def protected_route(payload: dict = Depends(verify_jwt)):
    return {"message": "Access granted to protected API route"}

# Mount static files
app.mount("/static", StaticFiles(directory="public"), name="static")

# Define hello_world function directly
def hello_world():
    return {
        "message": "Hello, World!",
        "status": "success"
    }

@app.post("/api/v1/hello")
async def run_hello_world(payload: dict = Depends(verify_jwt)):
    try:
        result = hello_world()
        return JSONResponse(content=result)
    except Exception as e:
        raise HTTPException(
            status_code=500,
            detail=f"Error executing Python script: {str(e)}"
        )

# Add other routes as needed... 