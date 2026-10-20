import json
from pathlib import Path

from fastapi import FastAPI
from pydantic import BaseModel

app = FastAPI()
ITEMS = Path(__file__).with_name("items.json")


class NewItem(BaseModel):
    name: str
    price: float


@app.get("/health")
def health():
    return {"status": "ok"}


@app.get("/items")
def items():
    return json.loads(ITEMS.read_text())


@app.post("/items")
def add(item: NewItem):
    stored = json.loads(ITEMS.read_text())
    new = {"id": max((i["id"] for i in stored), default=0) + 1, **item.model_dump()}
    ITEMS.write_text(json.dumps(stored + [new], indent=2))
    return new
