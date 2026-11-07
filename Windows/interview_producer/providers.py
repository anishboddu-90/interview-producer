"""Explicit compatible HTTPS APIs; no credential discovery or implicit fallback."""
from dataclasses import dataclass
import hashlib
import json
import re
import urllib.error
import urllib.parse
import urllib.request
import uuid


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


@dataclass(frozen=True)
class Provider:
    base: str
    model: str
    token_parameter: str = "max_completion_tokens"

    def endpoint(self, path):
        url = urllib.parse.urlsplit(self.base)
        if (url.scheme != "https" or not url.hostname or url.username or url.password or url.query or url.fragment
                or ".." in url.path or not self.model.strip() or len(self.model) > 200
                or self.token_parameter not in {"max_tokens","max_completion_tokens"}):
            raise ValueError("Enter an HTTPS API base without credentials/query/fragment, and an explicit model ID.")
        return self.base.rstrip("/")+"/"+path

    def account(self, kind):
        self.endpoint("validate")
        return kind+"-"+hashlib.sha256(self.base.rstrip("/").encode()).hexdigest()[:24]

    def save_key(self, kind, key):
        # keyring delegates to Windows Credential Locker; never plaintext configuration.
        import keyring
        from keyring.backends.Windows import WinVaultKeyring
        backend = WinVaultKeyring()
        if key:
            backend.set_password("InterviewProducer",self.account(kind),key)
        else:
            try:
                backend.delete_password("InterviewProducer",self.account(kind))
            except keyring.errors.PasswordDeleteError:
                pass

    def key(self, kind):
        from keyring.backends.Windows import WinVaultKeyring
        key = WinVaultKeyring().get_password("InterviewProducer",self.account(kind))
        if not key:
            raise ValueError(f"Save a {kind} key for this exact endpoint in Connection.")
        return key

    def post(self, path, kind, body, content_type):
        request = urllib.request.Request(self.endpoint(path),data=body,headers={"Authorization":"Bearer "+self.key(kind),"Content-Type":content_type},method="POST")
        try:
            with urllib.request.build_opener(NoRedirect()).open(request,timeout=60) as response:
                data = response.read(2_000_001)
                if len(data) > 2_000_000:
                    raise ValueError("Provider response exceeds 2 MB.")
                return json.loads(data)
        except urllib.error.HTTPError as error:
            raise ValueError(f"{kind} API HTTP {error.code}. Check endpoint/model/quota; no provider switch was made.") from None
        except urllib.error.URLError:
            raise ValueError("Provider connection failed. Audio and received transcript remain local.") from None

    def text(self, instructions, context):
        body = json.dumps({"model":self.model,"messages":[{"role":"system","content":instructions},{"role":"user","content":context}],self.token_parameter:6000,"stream":False,"store":False}).encode()
        result = self.post("chat/completions","text",body,"application/json")
        try:
            first = result["choices"][0]
            if first["finish_reason"] != "stop" or not first["message"]["content"]:
                raise ValueError("Incomplete model output; response was not used.")
            return first["message"]["content"]
        except (KeyError,IndexError,TypeError):
            raise ValueError("Unsupported text response; choose a chat-completions compatible model.") from None

    def transcribe(self, wav, language="auto"):
        if language != "auto" and not re.fullmatch(r"[a-zA-Z]{2,3}",language):
            raise ValueError("Language must be auto or a 2–3 letter ISO code.")
        boundary = "interview-"+uuid.uuid4().hex
        fields = {"model":self.model,"response_format":"json"}
        if language != "auto":
            fields["language"] = language
        body = b""
        for name,value in fields.items():
            body += f'--{boundary}\r\nContent-Disposition: form-data; name="{name}"\r\n\r\n{value}\r\n'.encode()
        body += f'--{boundary}\r\nContent-Disposition: form-data; name="file"; filename="chunk.wav"\r\nContent-Type: audio/wav\r\n\r\n'.encode()+wav+f'\r\n--{boundary}--\r\n'.encode()
        result = self.post("audio/transcriptions","audio",body,"multipart/form-data; boundary="+boundary)
        if not isinstance(result.get("text"),str):
            raise ValueError("Transcription response has no text.")
        return result["text"]
