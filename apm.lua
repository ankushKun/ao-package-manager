json = require("json")
base64 = require(".base64")
sqlite3 = require("lsqlite3")
bint = require('.bint')(256)

db = db or sqlite3.open_memory()

local utils = {
    add = function(a, b)
        return tostring(bint(a) + bint(b))
    end,
    subtract = function(a, b)
        return tostring(bint(a) - bint(b))
    end,
    toBalanceValue = function(a)
        return tostring(bint(a))
    end,
    toNumber = function(a)
        return tonumber(a)
    end
}

------------------------------------------------------ 101000000.0000000000
-- Load the token blueprint after apm.lua
Denomination = 10
Balances = Balances or { [ao.id] = utils.toBalanceValue(101000000 * 10 ^ Denomination) }
TotalSupply = TotalSupply or utils.toBalanceValue(101000000 * 10 ^ Denomination)
Name = "Test NEO"
Ticker = 'TNEO'
Logo = 'zExoVE0178jbyUg2MP-cK6SbBRFiNDynB5FRqeD0yJc'

------------------------------------------------------

db:exec([[
    CREATE TABLE IF NOT EXISTS Packages (
        ID INTEGER PRIMARY KEY AUTOINCREMENT,
        Name TEXT NOT NULL,
        Version TEXT NOT NULL,
        Vendor TEXT DEFAULT "@apm",
        Owner TEXT NOT NULL,
        README TEXT NOT NULL,
        PkgID TEXT NOT NULL,
        Items VARCHAR NOT NULL,
        Authors_ TEXT NOT NULL,
        Dependencies TEXT NOT NULL,
        Main TEXT NOT NULL,
        Description TEXT NOT NULL,
        RepositoryUrl TEXT NOT NULL,
        Updated INTEGER NOT NULL,
        Installs INTEGER DEFAULT 0
    );
    CREATE TABLE IF NOT EXISTS Vendors (
        ID INTEGER PRIMARY KEY AUTOINCREMENT,
        Name TEXT NOT NULL,
        Owner TEXT NOT NULL
    );
    -- TODO:
    CREATE TABLE IF NOT EXISTS Latest10 (
        ID INTEGER PRIMARY KEY AUTOINCREMENT,
        PkgID TEXT NOT NULL
    );
    CREATE TABLE IF NOT EXISTS Featured (
        ID INTEGER PRIMARY KEY AUTOINCREMENT,
        PkgID TEXT NOT NULL
    );
]])

------------------------------------------------------

function hexencode(str)
    return (str:gsub(".", function(char) return string.format("%02x", char:byte()) end))
end

function hexdecode(hex)
    return (hex:gsub("%x%x", function(digits) return string.char(tonumber(digits, 16)) end))
end

function isValidVersion(variant)
    return variant:match("^%d+%.%d+%.%d+$")
end

function isValidPackageName(name)
    return name:match("^[a-zA-Z0-9%-_]+$")
end

function isValidVendor(name)
    return name:match("^@%w+$")
end

-- common error handler
function handle_run(func, msg)
    local ok, err = pcall(func, msg)
    if not ok then
        local clean_err = err:match(":%d+: (.+)") or err
        print(msg.Action .. " - " .. err)
        -- Handlers.utils.reply(clean_err)(msg)
        if not msg.Target == ao.id then
            ao.send({
                Target = msg.From,
                Data = clean_err,
                Result = "error"
            })
        end
    end
end

-- easier query exec
function sql_run(query)
    local m = {}
    for row in db:nrows(query) do
        table.insert(m, row)
    end
    return m
end

function ListPackages()
    local p_str = "\n"
    local p = sql_run([[WITH UniqueNames AS (
    SELECT
        MAX(Version) AS Version, *
    FROM
        Packages
    GROUP BY
        Name
)
SELECT
    Vendor,
    Name,
    Version,
    Owner,
    RepositoryUrl,
    Description,
    Installs,
    PkgID
FROM
    UniqueNames;]])

    if #p == 0 then
        return "No packages found"
    end

    for _, pkg in ipairs(p) do
        -- p_str = p_str .. pkg.Vendor .. "/" .. pkg.Name .. "@" .. pkg.Version .. " - " .. pkg.Owner .. "\n"
        p_str = p_str ..
            pkg.Vendor .. "/" .. pkg.Name .. "@" .. pkg.Version .. " - " .. pkg.Owner .. " - " .. pkg.RepositoryUrl or
            "no url" .. " - " .. pkg.Description .. " - " .. pkg.Installs .. " installs\n"
    end
    return p_str
end

------------------------------------------------------

function RegisterVendor(msg)
    local cost = utils.toBalanceValue(10 * 10 ^ Denomination)
    local data = json.decode(msg.Data)
    local name = data.Name
    local owner = msg.From

    assert(type(msg.Quantity) == 'string', 'Quantity is required!')
    assert(bint(msg.Quantity) <= bint(Balances[msg.From]), 'Quantity must be less than or equal to the current balance!')
    assert(msg.Quantity == cost, "10 NEO must be burnt to registering a new vendor")


    assert(name, "❌ vendor name is required")
    assert(isValidVendor(name), "❌ Invalid vendor name, must be in the format @vendor")
    assert(name ~= "@apm", "❌ @apm can't be registered as vendor")
    assert(name ~= "@registry", "❌ @registry can't be registered as vendor")
    -- size 3 to 20
    assert(#name > 3 and #name <= 20, "❌ Vendor name must be between 3 and 20 characters")

    for row in db:nrows(string.format([[
        SELECT * FROM Vendors WHERE Name = "%s"
        ]], name)) do
        assert(nil, "❌ " .. name .. " already exists")
    end

    print("ℹ️ register requested for: " .. name .. " by " .. owner)

    db:exec(string.format([[
        INSERT INTO Vendors (Name, Owner) VALUES ("%s", '%s')
    ]], name, owner))

    Balances[msg.From] = utils.subtract(Balances[msg.From], msg.Quantity)
    TotalSupply = utils.subtract(TotalSupply, msg.Quantity)

    ao.send({
        Target = msg.From,
        Data = "Successfully burned " .. msg.Quantity 
    })

    -- Handlers.utils.reply("🎉 " .. name .. " registered")(msg)
    ao.send({
        Target = msg.From,
        Action = "APM.RegisterVendorResponse",
        Result = "success",
        Data = "🎉 " .. name .. " registered"
    })
end

Handlers.add(
    "RegisterVendor",
    Handlers.utils.hasMatchingTag("Action", "APM.RegisterVendor"),
    function(msg)
        handle_run(RegisterVendor, msg)
    end
)

------------------------------------------------------

function Publish(msg)
    local cost_new = utils.toBalanceValue(10 * 10 ^ Denomination)
    local cost_update = utils.toBalanceValue(1 * 10 ^ Denomination)
    local data = json.decode(msg.Data)
    local name = data.Name
    local version = data.Version
    local vendor = data.Vendor or "@apm"
    local package_data = data.PackageData
    local owner = msg.From

    -- Prevent publishing on registry process coz assignments have the Tag Action:Publish, which could cause a race condition?
    if ao.id == msg.From then
        error("❌ Registry cannot publish packages to itself")
    end

    assert(type(msg.Quantity) == 'string', 'Quantity is required!')
    assert(Balances[msg.From], "❌ You don't have any $NEO balance")
    assert(bint(msg.Quantity) <= bint(Balances[msg.From]), 'Quantity must be less than or equal to the current balance!')
    
    
    assert(type(name) == "string", "❌ Package name is required")
    assert(type(version) == "string", "❌ Package version is required")
    assert(type(vendor) == "string", "❌ vendor is required")
    assert(type(package_data) == "table", "❌ PackageData is required")
    
    assert(isValidPackageName(name), "Invalid package name, only alphanumeric characters are allowed")
    assert(isValidVersion(version), "Invalid package version, must be in the format major.minor.patch")
    assert(isValidVendor(vendor), "Invalid vendor name, must be in the format @vendor")

    assert(type(package_data.Readme) == "string", "❌ Readme(string) is required in PackageData")
    assert(type(package_data.RepositoryUrl) == "string", "❌ RepositoryUrl(string) is required in PackageData")
    assert(type(package_data.Items) == "table", "❌ Items(table) is required in PackageData")
    assert(type(package_data.Description) == "string", "❌ Description(string) is required in PackageData")
    assert(type(package_data.Authors) == "table", "❌ Authors(table) is required in PackageData")
    assert(type(package_data.Dependencies) == "table", "❌ Dependencies(table) is required in PackageData")
    assert(type(package_data.Main) == "string", "❌ Main(string) is required in PackageData")
    
    
    package_data.Readme = hexencode(package_data.Readme)
    
    -- print(vendor)
    -- if the package was published before, check the owner
    local existing = sql_run(string.format([[
        SELECT * FROM Packages WHERE Name = "%s" AND Vendor = "%s" ORDER BY Version DESC LIMIT 1
    ]], name, vendor))

    -- print(existing)

    if #existing > 0 then
        assert(existing[1].Owner == owner,
        "❌ You are not the owner of previously published " .. vendor .. "/" .. name .. "@" .. version)
        assert(msg.Quantity == cost_update,
            "1 NEO must be burnt to update an existing package. You sent: " .. tostring(bint(msg.Quantity) / 10^Denomination))
    else
        assert(
            msg.Quantity == cost_new,
            "10 NEO must be burnt to publish a new package. You sent: " .. tostring(bint(msg.Quantity) / 10^Denomination)
        )
    end
            

    -- check validity of Items
    for _, item in ipairs(package_data.Items) do
        assert(type(item.meta) == "table", "❌ meta(table) is required in Items")
        assert(type(item.data) == "string", "❌ data(string) is required in Items")
        for key, value in pairs(item.meta) do
            assert(type(key) == "string", "❌ meta key must be a string")
            assert(type(value) == "string", "❌ meta value must be a string")
        end
        -- item.data = base64.encode(item.data)
    end
    -- package_data.Items = base64.encode(json.encode(package_data.Items))
    -- print(package_data.Items)
    -- print(hexencode(json.encode(package_data.Items)))
    package_data.Items = hexencode(json.encode(package_data.Items))

    -- Items is valid

    -- check validity of Dependencies
    for _, dependency in ipairs(package_data.Dependencies) do
        assert(type(dependency) == "string", "❌ dependency must be a string")
    end
    package_data.Dependencies = json.encode(package_data.Dependencies)
    -- Dependencies is valid

    -- check validity of Authors
    for _, author in ipairs(package_data.Authors) do
        assert(type(author) == "string", "❌ author must be a string")
    end
    package_data.Authors = json.encode(package_data.Authors)
    -- Authors is valid

    if vendor ~= "@apm" then
        local v = sql_run(string.format([[
            SELECT * FROM Vendors WHERE Name = "%s"
        ]], vendor))
        assert(#v > 0, "❌ " .. vendor .. " does not exist")
        assert(v[1].Owner == owner, "❌ You are not the owner of " .. vendor)
    end

    -- check if the package already exists with same version
    local existing = sql_run(string.format([[
        SELECT * FROM Packages WHERE Name = "%s" AND Version = "%s" AND Vendor = "%s"
    ]], name, version, vendor))
    assert(#existing == 0, "❌ " .. vendor .. "/" .. name .. "@" .. version .. " already exists")

    -- insert the package
    local db_res = db:exec(string.format([[
        INSERT INTO Packages (
            Name, Version, Vendor, Owner, README, PkgID, Items, Authors_, Dependencies, Main, Description, RepositoryUrl, Updated
        ) VALUES (
            "%s", "%s", "%s", '%s', "%s", "%s", "%s", "%s", "%s", "%s", "%s", "%s", %s
        );
    ]], name, version, vendor, owner, package_data.Readme, msg.Id, package_data.Items, package_data.Authors,
        package_data.Dependencies, package_data.Main, package_data.Description, package_data.RepositoryUrl, os.time()))

    assert(db_res == 0, "❌[insert error] " .. db:errmsg())

    print("ℹ️ new package: " .. vendor .. "/" .. name .. "@" .. version .. " by " .. owner)

    Balances[msg.From] = utils.subtract(Balances[msg.From], msg.Quantity)
    TotalSupply = utils.subtract(TotalSupply, msg.Quantity)

    ao.send({
        Target = msg.From,
        Data = "Successfully burned " .. msg.Quantity
    })

    -- Handlers.utils.reply("🎉 " .. name .. "@" .. version .. " published")(msg)
    ao.send({
        Target = msg.From,
        Action = "APM.PublishResponse",
        Result = "success",
        Data = "🎉 " .. vendor .. "/" .. name .. "@" .. version .. " published"
    })
end

Handlers.add(
    "Publish",
    Handlers.utils.hasMatchingTag("Action", "APM.Publish"),
    function(msg)
        handle_run(Publish, msg)
    end
)

------------------------------------------------------

function Info(msg)
    local data = json.decode(msg.Data)
    local name = data.Name
    local version = data.Version or "latest"
    local pkgID = data.PkgID

    if pkgID then
        local package = sql_run(string.format([[
            SELECT * FROM Packages WHERE PkgID = "%s"
        ]], pkgID))
        assert(#package > 0, "❌ Package not found")

        -- all available versions and their pkg id
        local versions = sql_run(string.format([[
            SELECT Version, PkgID, Installs FROM Packages WHERE Name = "%s" AND Vendor = "%s"
        ]], package[1].Name, package[1].Vendor))

        package[1].Versions = versions

        -- Handlers.utils.reply(json.encode(package[1]))(msg)
        ao.send({
            Target = msg.From,
            Action = "APM.InfoResponse",
            Status = "success",
            Data = json.encode(package[1])
        })
        return
    end

    -- if name is @vendor/name
    local vendor, pkg_name = name:match("^@(%w+)/(.+)$")
    if vendor then
        name = pkg_name
        vendor = "@" .. vendor
    else
        vendor = "@apm"
    end

    -- print(vendor)
    -- print(name)
    -- print(version)

    assert(name, "Package name is required")
    assert(isValidPackageName(name), "Invalid package name, only alphanumeric characters are allowed")
    assert(isValidVendor(vendor), "Invalid vendor name, must be in the format @vendor")
    if version ~= "latest" then
        assert(isValidVersion(version), "Invalid package version, must be in the format major.minor.patch")
    end

    local package
    if version == "latest" then
        package = sql_run(string.format([[
            SELECT * FROM Packages WHERE Name = "%s" AND Vendor = "%s" ORDER BY Version DESC LIMIT 1
        ]], name, vendor))
    else
        package = sql_run(string.format([[
            SELECT * FROM Packages WHERE Name = "%s" AND Vendor = "%s" AND Version = "%s"
            ]], name, vendor, version))
    end

    assert(#package > 0, "❌ " .. name .. "@" .. version .. " not found")

    -- all available versions and their pkg id
    local versions = sql_run(string.format([[
        SELECT Version, PkgID, Installs FROM Packages WHERE Name = "%s" AND Vendor = "%s"
    ]], name, vendor))

    package[1].Versions = versions

    -- Handlers.utils.reply(json.encode(package[1]))(msg)
    ao.send({
        Target = msg.From,
        Action = "APM.InfoResponse",
        Data = json.encode(package[1])
    })
end

Handlers.add(
    "Info",
    Handlers.utils.hasMatchingTag("Action", "APM.Info"),
    function(msg)
        handle_run(Info, msg)
    end
)

------------------------------------------------------

function GetAllPackages(msg)
    local packages = sql_run([[
        WITH UniqueNames AS (
    SELECT
        MAX(Version) AS Version, *
    FROM
        Packages
    GROUP BY
        Name
    ORDER BY
        Installs DESC
    LIMIT 50
)
SELECT
    Vendor,
    Name,
    Version,
    Owner,
    RepositoryUrl,
    Description,
    Installs,
    Updated,
    PkgID
FROM
    UniqueNames;
    ]])
    print(packages)
    -- Handlers.utils.reply(json.encode(packages))(msg)
    ao.send({
        Target = msg.From,
        Action = "APM.GetAllPackagesResponse",
        Data = json.encode(packages)
    })
end

Handlers.add(
    "GetAllPackages",
    Handlers.utils.hasMatchingTag("Action", "APM.GetAllPackages"),
    function(msg)
        handle_run(GetAllPackages, msg)
    end
)

------------------------------------------------------

function Download(msg)
    local data = json.decode(msg.Data)
    local name = data.Name
    local version = data.Version or "latest"
    local vendor = data.Vendor or "@apm"

    -- Prevent installation on registry process coz assignments have the Tag Action:Publish, which could cause a race condition?
    if msg.From == ao.id then
        error("❌ Cannot install pacakges on the registry process")
    end

    assert(name, "❌ Package name is required")

    local res
    if version == "latest" then
        res = sql_run(string.format([[
            SELECT * FROM Packages WHERE Name = "%s" AND Vendor = "%s" ORDER BY Version DESC LIMIT 1
        ]], name, vendor))
    else
        res = sql_run(string.format([[
            SELECT * FROM Packages WHERE Name = "%s" AND Version = "%s" AND Vendor = "%s"
        ]], name, version, vendor))
    end

    assert(#res > 0, "❌ " .. vendor .. "/" .. name .. "@" .. version .. " not found")

    --  increment installs
    local inc_res = db:exec(string.format([[
        UPDATE Packages SET Installs = Installs + 1 WHERE Name = "%s" AND Version = "%s" AND Vendor = "%s"
    ]], name, res[1].Version, vendor))
    print(inc_res)


    Assign({
        Processes = { msg.From },
        Message = res[1].PkgID
    })

    print("ℹ️ Download request for " .. vendor .. "/" .. name .. "@" .. res[1].Version .. " from " .. msg.From)
    -- ao.send({
    --     Target = msg.From,
    --     Action = "APM.DownloadResponse",
    --     Data = json.encode(res[1])
    -- })
end

Handlers.add(
    "Download",
    Handlers.utils.hasMatchingTag("Action", "APM.Download"),
    function(msg)
        handle_run(Download, msg)
    end
)

------------------------------------------------------

function Transfer(msg)
    local data = json.decode(msg.Data)
    local name = data.Name
    local vendor = data.Vendor or "@apm"
    local new_owner = msg.To

    assert(name, "❌ Package name is required")
    assert(new_owner, "❌ New owner is required")

    local res = sql_run(string.format([[
        SELECT * FROM Packages WHERE Name = "%s" AND Vendor = "%s" ORDER BY Version DESC LIMIT 1
    ]], name, vendor))

    assert(#res > 0, "❌ " .. vendor .. "/" .. name .. " not found")

    -- user should be either the owner of the package or the vendor
    assert(res[1].Owner == msg.From or res[1].Vendor == msg.From, "❌ You are not the owner of " .. vendor .. "/" .. name)

    -- Update owner of the latest version of the package
    db:exec(string.format([[
        UPDATE Packages SET Owner = '%s' WHERE Name = "%s" AND Vendor = "%s" AND Version = "%s"
    ]], new_owner, name, vendor, res[1].Version))

    print("ℹ️ Transfer requested for " .. vendor .. "/" .. name .. " to " .. new_owner)
    -- Handlers.utils.reply("🎉 " .. vendor .. "/" .. name .. " transferred to " .. new_owner)(msg)
    ao.send({
        Target = msg.From,
        Action = "APM.TransferResponse",
        Data = "🎉 " .. vendor .. "/" .. name .. " transferred to " .. new_owner
    })
end

Handlers.add(
    "Transfer",
    Handlers.utils.hasMatchingTag("Action", "APM.Transfer"),
    function(msg)
        handle_run(Transfer, msg)
    end
)

------------------------------------------------------


function Search(msg)
    local query = msg.Data

    assert(type(query) == "string", "❌ Search query is required in Data")

    -- match either name or vendor
    local packages = sql_run(string.format([[
        SELECT DISTINCT Name, Vendor, Description, PkgID, Version, Installs FROM Packages WHERE Name LIKE "%%%s%%" OR Vendor LIKE "%%%s%%"
    ]], query, query))

    -- Handlers.utils.reply(json.encode(packages))(msg)
    ao.send({
        Target = msg.From,
        Action = "APM.SearchResponse",
        Data = json.encode(packages)
    })
end

Handlers.add(
    "Search",
    Handlers.utils.hasMatchingTag("Action", "APM.Search"),
    function(msg)
        handle_run(Search, msg)
    end
)

------------------------------------------------------

return "📦 Loaded APM"
