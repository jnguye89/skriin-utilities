using WifiSetupService;

var builder = Host.CreateApplicationBuilder(args);
builder.Services.AddWindowsService(options => options.ServiceName = "SkriinWifiSetup");
builder.Services.AddSingleton<WifiHelper>();
builder.Services.AddHostedService<SetupOrchestrator>();

var host = builder.Build();
host.Run();
