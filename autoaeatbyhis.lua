-- Auto Eat (contoh gaya "99 Nights in the Forest")
-- Tinggal sesuaikan nama Hunger / Inventory / fungsi makan dengan game kamu

local player = game.Players.LocalPlayer
local hunger = player:WaitForChild("Hunger") -- ValueObject hunger

-- Fungsi cari makanan di backpack
local function getFood()
    for _, item in ipairs(player.Backpack:GetChildren()) do
        if item:IsA("Tool") and item:FindFirstChild("Nutrition") then
            return item
        end
    end
    return nil
end

-- Fungsi makan
local function eat(food)
    if food and food:FindFirstChild("Activate") then
        food:Activate() -- gaya umum "gunakan tool"
        print("Makan:", food.Name)
    elseif food then
        -- fallback kalau sistem makan beda
        print("Item ditemukan tapi tidak bisa di-activate:", food.Name)
    else
        print("Tidak ada makanan.")
    end
end

-- Loop auto makan
while task.wait(1) do
    if hunger.Value >= 70 then -- ambang lapar, bisa kamu ubah
        local food = getFood()
        if food then
            eat(food)
        else
            warn("Kamu lapar tapi tidak ada makanan di backpack!")
        end
    end
end
