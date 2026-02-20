from fastapi import FastAPI, Request
from fastapi.responses import FileResponse, PlainTextResponse
from fastapi.staticfiles import StaticFiles
from pydantic import BaseModel
from typing import Optional
from pathlib import Path
 
from frontend_impl import RIGHTS_TEXT, ui_mint, ui_predict_with_ect, ui_members_all

app = FastAPI()

 
BASE = Path(__file__).resolve().parent
STATIC = BASE / "static"
app.mount("/static", StaticFiles(directory=str(STATIC)), name="static")

@app.get("/")
def root():
    return FileResponse(str(STATIC / "index.html"))

@app.get("/index.html")
def index_html():
    return FileResponse(str(STATIC / "index.html"))

@app.get("/rights", response_class=PlainTextResponse)
def rights():
    return RIGHTS_TEXT 


class MintReq(BaseModel):
    org_id: str
    sub: str
    cohort: str
    nbf: Optional[str] = None
    exp: Optional[str] = None

@app.post("/mint")
def mint(req: MintReq):
    return ui_mint(req.org_id, req.sub, req.cohort, req.nbf, req.exp)



class PredictReq(BaseModel):
    org_id: str
    sub: str
    envelope_id: str
    cohort: str
    digit: int
    topk: Optional[int] = 3
    jti: str
    ect: str  # REQUIRED: two-step protocol (mint then predict)


@app.post("/predict")
def predict(req: PredictReq):
    return ui_predict_with_ect(req)


@app.get("/members")
def members():
    return ui_members_all()

