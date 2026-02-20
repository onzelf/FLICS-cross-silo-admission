 # backends/flower_client/client.py
import os
import time
import flwr as fl
import torch
import torch.nn as nn
import torch.optim as optim
import torchvision
import torchvision.transforms as T

ROLE = os.getenv("ROLE", "even")
SERVER = os.getenv("SERVER_ADDRESS", "flower-server:8080")
EPOCHS = int(os.getenv("LOCAL_EPOCHS", "1"))
LR = float(os.getenv("LEARNING_RATE", "0.01"))

MAX_RETRIES = 60  # 10 minutes with 10s intervals
RETRY_INTERVAL = 10  # seconds

def now() -> str:
    return time.strftime("%Y-%m-%d %H:%M:%S", time.localtime())

class Net(nn.Module):
    def __init__(self):
        super().__init__()
        self.seq = nn.Sequential(
            nn.Conv2d(1, 32, 3, 1), nn.ReLU(), nn.MaxPool2d(2),
            nn.Conv2d(32, 64, 3, 1), nn.ReLU(), nn.MaxPool2d(2),
            nn.Flatten(), nn.Linear(1600, 128), nn.ReLU(),
            nn.Linear(128, 10)
        )
    def forward(self, x):
        return self.seq(x)

def make_loader():
    tfm = T.Compose([T.ToTensor()])
    ds = torchvision.datasets.MNIST("/tmp/mnist", train=True, download=True, transform=tfm)
    # Split by digit parity
    idx = [i for i in range(len(ds)) if (ds.targets[i] % 2 == 0) == (ROLE == "even")]
    sub = torch.utils.data.Subset(ds, idx)
    return torch.utils.data.DataLoader(sub, batch_size=64, shuffle=True)

device = "cuda" if torch.cuda.is_available() else "cpu"
model = Net().to(device)
loss_fn = nn.CrossEntropyLoss()
loader = make_loader()

class FlowerClient(fl.client.NumPyClient):
    def get_parameters(self, config):
        return [p.detach().cpu().numpy() for p in model.parameters()]

    def fit(self, parameters, config):
        for p, pp in zip(model.parameters(), parameters):
            p.data = torch.tensor(pp, device=device)
        
        opt = optim.SGD(model.parameters(), lr=LR)
        model.train()
        for _ in range(EPOCHS):
            for X, y in loader:
                X, y = X.to(device), y.to(device)
                opt.zero_grad()
                out = model(X)
                loss = loss_fn(out, y)
                loss.backward()
                opt.step()
        
        return self.get_parameters({}), len(loader.dataset), {}

    def evaluate(self, parameters, config):
        for p, pp in zip(model.parameters(), parameters):
            p.data = torch.tensor(pp, device=device)
        
        tfm = T.Compose([T.ToTensor()])
        test = torchvision.datasets.MNIST("/tmp/mnist", train=False, download=True, transform=tfm)
        test_loader = torch.utils.data.DataLoader(test, batch_size=256, shuffle=False)
        
        model.eval()
        correct, total, loss_sum = 0, 0, 0.0
        with torch.no_grad():
            for X, y in test_loader:
                X, y = X.to(device), y.to(device)
                out = model(X)
                loss_sum += loss_fn(out, y).item() * X.size(0)
                pred = out.argmax(1)
                correct += (pred == y).sum().item()
                total += X.size(0)
        
        return loss_sum / total, total, {"accuracy": correct / total}

if __name__ == "__main__":
    print(f"[{ROLE}:{now()}] Attempting to connect to {SERVER}")
    
    for attempt in range(1, MAX_RETRIES + 1):
        try:
            print(f"[{ROLE}:{now()}] Connection attempt {attempt}/{MAX_RETRIES}...")
            fl.client.start_numpy_client(server_address=SERVER, client=FlowerClient())
            print(f"[{ROLE}] fl.client.start_numpy_client returned" )
            break
        except Exception as ex:
            if attempt < MAX_RETRIES:
                print(f"[{ROLE}:{now()}] Connection failed: ({type(ex).__name__}): {ex}")
                print(f"[{ROLE}] Retrying in {RETRY_INTERVAL} seconds...")
                time.sleep(RETRY_INTERVAL)
            else:
                print(f"[{ROLE}:{now()}] Failed to connect after {MAX_RETRIES} attempts")
                raise

    print(f"[{ROLE}:{now()}] Exiting after attempt {attempt}")