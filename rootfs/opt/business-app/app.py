#!/usr/bin/env python3
"""
Business Logic Web Application Placeholder

This is a placeholder Flask application that should be replaced
with your actual business logic application.

Port: 8001
"""

from flask import Flask, jsonify

app = Flask(__name__)


@app.route('/')
def index():
    """Main page placeholder."""
    return '''
    <!DOCTYPE html>
    <html>
    <head>
        <title>Business Application</title>
        <style>
            body {
                font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif;
                display: flex;
                justify-content: center;
                align-items: center;
                height: 100vh;
                margin: 0;
                background: linear-gradient(135deg, #667eea 0%, #764ba2 100%);
                color: white;
            }
            .container {
                text-align: center;
                padding: 40px;
                background: rgba(255,255,255,0.1);
                border-radius: 16px;
                backdrop-filter: blur(10px);
            }
            h1 { margin-bottom: 10px; }
            p { opacity: 0.9; }
            code {
                background: rgba(0,0,0,0.2);
                padding: 2px 8px;
                border-radius: 4px;
            }
        </style>
    </head>
    <body>
        <div class="container">
            <h1>Business Application</h1>
            <p>This is a placeholder application.</p>
            <p>Replace <code>/opt/business-app/app.py</code> with your application.</p>
            <p>Running on port <code>8001</code></p>
        </div>
    </body>
    </html>
    '''


@app.route('/api/status')
def api_status():
    """Status endpoint."""
    return jsonify({
        'status': 'ok',
        'message': 'Business application placeholder is running',
        'port': 8001
    })


@app.route('/api/health')
def api_health():
    """Health check endpoint."""
    return jsonify({'healthy': True})


if __name__ == '__main__':
    app.run(host='0.0.0.0', port=8001, debug=False)
