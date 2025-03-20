# Building Web Apps with SupaFast LLM

This guide shows you how to build web applications that run on your SupaFast LLM setup. We'll cover two examples:
1. A simple "Hello World" app
2. An AI chat application using Ollama

## Example 1: Hello World Web App

This example shows how to create a basic web app that runs a Python script when a user clicks a button.

### 1. Create the Python Script
Create `public/hello.py`:
```python
def hello_world():
    return {
        "message": "Hello World from Python!",
        "status": "success"
    }
```

### 2. Create the Web Page
Create `public/index.html`:
```html
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>SupaFast LLM</title>
    <script src="https://cdn.jsdelivr.net/npm/@supabase/supabase-js@2"></script>
    <style>
        body {
            font-family: Arial, sans-serif;
            max-width: 800px;
            margin: 0 auto;
            padding: 20px;
        }
        .container {
            background-color: #f5f5f5;
            border-radius: 8px;
            padding: 20px;
        }
        button {
            background-color: #4CAF50;
            color: white;
            padding: 10px 20px;
            border: none;
            border-radius: 4px;
            cursor: pointer;
        }
        #result {
            margin-top: 20px;
            padding: 15px;
            border-radius: 4px;
            background-color: #fff;
            border: 1px solid #ddd;
            display: none;
        }
    </style>
</head>
<body>
    <h1>Hello World Demo</h1>
    
    <div class="container">
        <button onclick="runPythonScript()">Run Hello World</button>
        <div id="result"></div>
    </div>

    <script>
        const supabase = supabase.createClient(
            window.location.origin,
            'your-anon-key'  // Will be replaced with your Supabase anon key
        );

        async function runPythonScript() {
            try {
                const { data: { session } } = await supabase.auth.getSession();
                if (!session) throw new Error('Please log in first');

                const response = await fetch('/api/v1/hello', {
                    method: 'POST',
                    headers: {
                        'Authorization': `Bearer ${session.access_token}`,
                        'Content-Type': 'application/json'
                    }
                });

                const data = await response.json();
                document.getElementById('result').style.display = 'block';
                document.getElementById('result').innerHTML = 
                    `<p style="color: #4CAF50">${data.message}</p>`;
            } catch (error) {
                document.getElementById('result').style.display = 'block';
                document.getElementById('result').innerHTML = 
                    `<p style="color: #f44336">Error: ${error.message}</p>`;
            }
        }
    </script>
</body>
</html>
```

### 3. Add FastAPI Endpoint
Add to `fastapi/main.py`:
```python
from fastapi import FastAPI, HTTPException, Depends
from fastapi.security import HTTPBearer
import jwt

# Setup
security = HTTPBearer()

async def verify_jwt(credentials = Depends(security)):
    try:
        payload = jwt.decode(
            credentials.credentials,
            'your-jwt-secret',  # Replace with your JWT secret
            algorithms=['HS256']
        )
        return payload
    except:
        raise HTTPException(status_code=401)

@app.post("/api/v1/hello")
async def run_hello_world(payload: dict = Depends(verify_jwt)):
    from hello import hello_world
    return hello_world()
```

## Example 2: AI Chat with Ollama

### Prerequisites: Setting Up Ollama

Before building the chat application, you need to ensure Ollama is properly set up:

1. **Check Ollama Installation**:
   ```bash
   # Check if Ollama is running in Docker
   docker compose ps ollama

   # Check Ollama version
   curl http://localhost:11434/api/version
   ```

2. **List Available Models**:
   ```bash
   # List all installed models
   curl http://localhost:11434/api/tags

   # Or using ollama command if installed locally
   ollama list
   ```

3. **Install Required Models**:
   ```bash
   # Pull the Llama 2 model
   curl http://localhost:11434/api/pull -d '{
     "name": "llama2"
   }'

   # Or using ollama command
   ollama pull llama2
   ```

4. **Test Model Response**:
   ```bash
   # Test if model responds
   curl http://localhost:11434/api/generate -d '{
     "model": "llama2",
     "prompt": "Hello, are you working?"
   }'
   ```

5. **Common Model Commands**:
   ```bash
   # Remove a model
   ollama rm llama2

   # List model information
   ollama show llama2

   # Copy a model
   ollama cp llama2 my-llama2
   ```

### Troubleshooting Ollama

1. **Model Not Found Errors**:
   ```bash
   # Check available models again
   curl http://localhost:11434/api/tags

   # If model is missing, pull it
   curl http://localhost:11434/api/pull -d '{
     "name": "llama2"
   }'
   ```

2. **Memory Issues**:
   - Check Docker resources (memory limit)
   - Try a smaller model:
     ```bash
     # Pull a smaller model like Mistral
     curl http://localhost:11434/api/pull -d '{
       "name": "mistral"
     }'
     ```

3. **Port Issues**:
   ```bash
   # Check if port 11434 is in use
   lsof -i :11434

   # Verify Ollama is listening
   netstat -an | grep 11434
   ```

### 1. Create the Python Script
Create `public/llm_chat.py`:
```python
import httpx
import json

async def chat_with_llm(prompt: str):
    async with httpx.AsyncClient() as client:
        try:
            response = await client.post(
                'http://localhost:11434/api/generate',
                json={
                    "model": "llama2",
                    "prompt": prompt,
                    "stream": False
                }
            )
            return {
                "response": response.json()["response"],
                "status": "success"
            }
        except Exception as e:
            return {
                "error": str(e),
                "status": "error"
            }
```

### 2. Create the Web Interface
Create `public/chat.html`:
```html
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>AI Chat - SupaFast LLM</title>
    <script src="https://cdn.jsdelivr.net/npm/@supabase/supabase-js@2"></script>
    <style>
        body {
            font-family: Arial, sans-serif;
            max-width: 800px;
            margin: 0 auto;
            padding: 20px;
        }
        .chat-container {
            background-color: #f5f5f5;
            border-radius: 8px;
            padding: 20px;
            margin-top: 20px;
        }
        .input-area {
            display: flex;
            gap: 10px;
            margin-top: 20px;
        }
        textarea {
            flex: 1;
            padding: 10px;
            border-radius: 4px;
            border: 1px solid #ddd;
            min-height: 60px;
        }
        button {
            background-color: #4CAF50;
            color: white;
            padding: 10px 20px;
            border: none;
            border-radius: 4px;
            cursor: pointer;
        }
        .chat-messages {
            margin-top: 20px;
        }
        .message {
            padding: 10px;
            margin: 5px 0;
            border-radius: 4px;
        }
        .user-message {
            background-color: #e3f2fd;
        }
        .ai-message {
            background-color: #f5f5f5;
        }
    </style>
</head>
<body>
    <h1>AI Chat</h1>
    
    <div class="chat-container">
        <div class="chat-messages" id="messages"></div>
        <div class="input-area">
            <textarea id="prompt" placeholder="Type your message..."></textarea>
            <button onclick="sendMessage()">Send</button>
        </div>
    </div>

    <script>
        const supabase = supabase.createClient(
            window.location.origin,
            'your-anon-key'  // Will be replaced with your Supabase anon key
        );

        async function sendMessage() {
            const promptInput = document.getElementById('prompt');
            const prompt = promptInput.value.trim();
            if (!prompt) return;

            try {
                const { data: { session } } = await supabase.auth.getSession();
                if (!session) throw new Error('Please log in first');

                // Add user message to chat
                addMessage('user', prompt);
                promptInput.value = '';

                // Send to API
                const response = await fetch('/api/v1/chat', {
                    method: 'POST',
                    headers: {
                        'Authorization': `Bearer ${session.access_token}`,
                        'Content-Type': 'application/json'
                    },
                    body: JSON.stringify({ prompt })
                });

                const data = await response.json();
                if (data.status === 'error') throw new Error(data.error);
                
                // Add AI response to chat
                addMessage('ai', data.response);
            } catch (error) {
                addMessage('system', `Error: ${error.message}`);
            }
        }

        function addMessage(type, text) {
            const messages = document.getElementById('messages');
            const messageDiv = document.createElement('div');
            messageDiv.className = `message ${type}-message`;
            messageDiv.textContent = text;
            messages.appendChild(messageDiv);
            messages.scrollTop = messages.scrollHeight;
        }
    </script>
</body>
</html>
```

### 3. Add FastAPI Endpoints
Add to `fastapi/main.py`:
```python
from pydantic import BaseModel

class ChatRequest(BaseModel):
    prompt: str

@app.post("/api/v1/chat")
async def chat_endpoint(
    request: ChatRequest,
    payload: dict = Depends(verify_jwt)
):
    from llm_chat import chat_with_llm
    return await chat_with_llm(request.prompt)
```

## API Documentation

### Hello World API
```bash
# Endpoint: POST /api/v1/hello
# Headers:
Authorization: Bearer <your-jwt-token>
Content-Type: application/json

# Response:
{
    "message": "Hello World from Python!",
    "status": "success"
}
```

### Chat API
```bash
# Endpoint: POST /api/v1/chat
# Headers:
Authorization: Bearer <your-jwt-token>
Content-Type: application/json

# Request Body:
{
    "prompt": "Tell me about quantum computing"
}

# Response:
{
    "response": "Quantum computing is...",
    "status": "success"
}
```

## Using the APIs with curl

### Hello World Example:
```bash
# Get JWT token from Supabase
TOKEN="your-jwt-token"

# Call Hello World API
curl -X POST https://api.topaims.net/api/v1/hello \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json"
```

### Chat Example:
```bash
# Call Chat API
curl -X POST https://api.topaims.net/api/v1/chat \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"prompt": "Explain how quantum computers work"}'
```

## Using the APIs with Python

```python
import requests

def call_api(endpoint, prompt=None):
    headers = {
        "Authorization": f"Bearer {YOUR_JWT_TOKEN}",
        "Content-Type": "application/json"
    }
    
    url = f"https://api.topaims.net/api/v1/{endpoint}"
    
    if prompt:
        data = {"prompt": prompt}
        response = requests.post(url, headers=headers, json=data)
    else:
        response = requests.post(url, headers=headers)
    
    return response.json()

# Hello World example
result = call_api("hello")
print(result["message"])

# Chat example
chat_result = call_api("chat", "Tell me about quantum computing")
print(chat_result["response"])
```

## Tips for Development

1. **Testing Locally**:
   - Use `localhost` instead of `api.topaims.net`
   - Make sure Ollama is running (`docker compose logs ollama`)
   - Check FastAPI logs for errors (`docker compose logs fastapi`)

2. **Debugging**:
   - Add console.log() in JavaScript for frontend issues
   - Add print() statements in Python for backend issues
   - Check browser developer tools (F12) for network errors

3. **Security**:
   - Always verify JWT tokens
   - Use HTTPS in production
   - Never expose Ollama directly to the internet

4. **Performance**:
   - Consider adding caching for LLM responses
   - Use streaming for long responses
   - Implement request timeouts

## Common Issues and Solutions

1. **"Please log in first" error**:
   - Check if you're logged in to Supabase
   - Verify JWT token is being sent
   - Check token expiration

2. **Ollama not responding**:
   - Verify Ollama container is running
   - Check if model is downloaded
   - Verify port 11434 is accessible

3. **CORS errors**:
   - Check FastAPI CORS configuration
   - Verify allowed origins
   - Use correct protocol (http/https) 