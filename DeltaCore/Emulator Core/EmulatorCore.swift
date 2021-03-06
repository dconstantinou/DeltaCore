//
//  EmulatorCore.swift
//  DeltaCore
//
//  Created by Riley Testut on 3/11/15.
//  Copyright (c) 2015 Riley Testut. All rights reserved.
//

import AVFoundation

public extension EmulatorCore
{
    @objc enum State: Int
    {
        case stopped
        case running
        case paused
    }
    
    enum CheatError: Error
    {
        case invalid
    }
    
    enum SaveStateError: Error
    {
        case doesNotExist
    }
}

public final class EmulatorCore: NSObject
{
    //MARK: - Properties -
    /** Properties **/
    public let game: GameProtocol
    public private(set) var gameViews: [GameView] = []
    
    public var updateHandler: ((EmulatorCore) -> Void)?
    
    public private(set) lazy var audioManager: AudioManager = AudioManager(audioFormat: self.deltaCore.audioFormat, frameDuration: self.deltaCore.frameDuration)
    public private(set) lazy var videoManager: VideoManager = VideoManager(videoFormat: self.deltaCore.videoFormat)
    
    // KVO-Compliant
    @objc public private(set) dynamic var state = State.stopped
    @objc public dynamic var rate = 1.0 {
        didSet {
            self.audioManager.rate = self.rate
        }
    }
    
    public let deltaCore: DeltaCoreProtocol
    public var preferredRenderingSize: CGSize { return self.deltaCore.videoFormat.dimensions }
    
    //MARK: - Private Properties
    
    // We privately set this first to clean up before setting self.state, which notifies KVO observers
    private var _state = State.stopped
    
    private let gameType: GameType
    
    private let emulationSemaphore = DispatchSemaphore(value: 0)
    private var cheatCodes = [String: CheatType]()
    
    private var gameControllers = NSHashTable<AnyObject>.weakObjects()
    
    private var previousState = State.stopped
    private var previousRate: Double? = nil
    
    private var reactivateInputsSemaphores = Set<DispatchSemaphore>()
    private let reactivateInputsQueue = DispatchQueue(label: "com.rileytestut.DeltaCore.EmulatorCore.reactivateInputsQueue", attributes: [.concurrent])
    
    private var gameSaveURL: URL {
        let gameURL = self.game.fileURL.deletingPathExtension()
        let gameSaveURL = gameURL.appendingPathExtension(self.deltaCore.gameSaveFileExtension)
        return gameSaveURL
    }
    
    //MARK: - Initializers -
    /** Initializers **/
    public required init?(game: GameProtocol)
    {
        // These MUST be set in start(), because it's possible the same emulator core might be stopped, another one started, and then resumed back to this one
        // AKA, these need to always be set at start to ensure it points to the correct managers
        // self.configuration.bridge.audioRenderer = self.audioManager
        // self.configuration.bridge.videoRenderer = self.videoManager
        
        guard let deltaCore = Delta.core(for: game.type) else {
            print(game.type.rawValue + " is not a supported game type.")
            return nil
        }
        
        self.deltaCore = deltaCore
        
        self.game = game
        
        // Stored separately in case self.game is an NSManagedObject subclass, and we need to access .type on a different thread than its NSManagedObjectContext
        self.gameType = self.game.type
        
        super.init()
    }
}

//MARK: - Emulation -
/// Emulation
public extension EmulatorCore
{
    @discardableResult func start() -> Bool
    {
        guard self._state == .stopped else { return false }
        
        self._state = .running
        defer { self.state = self._state }
        
        self.audioManager.start()
        
        self.deltaCore.emulatorBridge.audioRenderer = self.audioManager
        self.deltaCore.emulatorBridge.videoRenderer = self.videoManager
        self.deltaCore.emulatorBridge.saveUpdateHandler = { [unowned self] in
            self.deltaCore.emulatorBridge.saveGameSave(to: self.gameSaveURL)
        }
        
        self.deltaCore.emulatorBridge.start(withGameURL: self.game.fileURL)
        self.deltaCore.emulatorBridge.loadGameSave(from: self.gameSaveURL)
        
        self.runGameLoop()
        
        self.emulationSemaphore.wait()
        
        return true
    }
    
    @discardableResult func stop() -> Bool
    {
        guard self._state != .stopped else { return false }
        
        let isRunning = self.state == .running
        
        self._state = .stopped
        defer { self.state = self._state }
        
        if isRunning
        {
            self.emulationSemaphore.wait()
        }
        
        self.deltaCore.emulatorBridge.saveGameSave(to: self.gameSaveURL)
        
        self.audioManager.stop()
        self.deltaCore.emulatorBridge.stop()
        
        return true
    }
    
    @discardableResult func pause() -> Bool
    {
        guard self._state == .running else { return false }
        
        self._state = .paused
        defer { self.state = self._state }
        
        self.emulationSemaphore.wait()
        
        self.deltaCore.emulatorBridge.saveGameSave(to: self.gameSaveURL)
        
        self.audioManager.isEnabled = false
        self.deltaCore.emulatorBridge.pause()
        
        return true
    }
    
    @discardableResult func resume() -> Bool
    {
        guard self._state == .paused else { return false }
        
        self._state = .running
        defer { self.state = self._state }
        
        self.audioManager.isEnabled = true
        self.deltaCore.emulatorBridge.resume()
        
        self.runGameLoop()
        
        self.emulationSemaphore.wait()
        
        return true
    }
}

//MARK: - Game Views -
/// Game Views
public extension EmulatorCore
{
    public func add(_ gameView: GameView)
    {
        self.gameViews.append(gameView)
        
        self.videoManager.add(gameView)
    }
    
    public func remove(_ gameView: GameView)
    {
        if let index = self.gameViews.index(of: gameView)
        {
            self.gameViews.remove(at: index)
        }
        
        self.videoManager.remove(gameView)
    }
}

//MARK: - Save States -
/// Save States
public extension EmulatorCore
{
    @discardableResult func saveSaveState(to url: URL) -> SaveStateProtocol
    {
        self.deltaCore.emulatorBridge.saveSaveState(to: url)
        
        let saveState = SaveState(fileURL: url, gameType: self.gameType)
        return saveState
    }
    
    func load(_ saveState: SaveStateProtocol) throws
    {
        guard FileManager.default.fileExists(atPath: saveState.fileURL.path) else { throw SaveStateError.doesNotExist }
        
        self.deltaCore.emulatorBridge.loadSaveState(from: saveState.fileURL)
        
        self.updateCheats()
        self.deltaCore.emulatorBridge.resetInputs()
        
        // Reactivate activated inputs.
        for gameController in self.gameControllers.allObjects as! [GameController]
        {
            for input in gameController.activatedInputs
            {
                gameController.activate(input)
            }
        }
    }
}

//MARK: - Cheats -
/// Cheats
public extension EmulatorCore
{
    func activate(_ cheat: CheatProtocol) throws
    {
        var success = true
        
        let codes = cheat.code.split(separator: "\n")
        for code in codes
        {
            if !self.deltaCore.emulatorBridge.addCheatCode(String(code), type: cheat.type)
            {
                success = false
                break
            }
        }
        
        if success
        {
            self.cheatCodes[cheat.code] = cheat.type
        }
        
        // Ensures correct state, especially if attempted cheat was invalid
        self.updateCheats()
        
        if !success
        {
            throw CheatError.invalid
        }
    }
    
    func deactivate(_ cheat: CheatProtocol)
    {
        guard self.cheatCodes[cheat.code] != nil else { return }
        
        self.cheatCodes[cheat.code] = nil
        
        self.updateCheats()
    }
    
    private func updateCheats()
    {
        self.deltaCore.emulatorBridge.resetCheats()
        
        for (cheatCode, type) in self.cheatCodes
        {
            let codes = cheatCode.split(separator: "\n")
            for code in codes
            {
                self.deltaCore.emulatorBridge.addCheatCode(String(code), type: type)
            }
        }
        
        self.deltaCore.emulatorBridge.updateCheats()
    }
}

extension EmulatorCore: GameControllerReceiver
{
    public func gameController(_ gameController: GameController, didActivate input: Input)
    {
        self.gameControllers.add(gameController)
        
        guard let input = self.mappedInput(for: input), input.type == .game(self.gameType) else { return }
        
        // If any of game controller's sustained inputs map to input, treat input as sustained.
        let isSustainedInput = gameController.sustainedInputs.contains(where: {
            guard let mappedInput = gameController.mappedInput(for: $0, receiver: self) else { return false }
            return self.mappedInput(for: mappedInput) == input
        })
        
        if isSustainedInput
        {
            self.reactivateInputsQueue.async {
                
                self.deltaCore.emulatorBridge.deactivateInput(input.intValue!)
                
                let semaphore = DispatchSemaphore(value: 0)
                self.reactivateInputsSemaphores.insert(semaphore)
                
                // To ensure the emulator core recognizes us activating an input that is currently active, we need to first deactivate it, wait at least two frames, then activate it again.
                // Unfortunately we cannot init DispatchSemaphore with value less than 0.
                // To compensate, we simply wait twice; once the first wait returns, we wait again.
                semaphore.wait()
                semaphore.wait()
                
                self.reactivateInputsSemaphores.remove(semaphore)
                
                self.deltaCore.emulatorBridge.activateInput(input.intValue!)
            }
        }
        else
        {
            self.deltaCore.emulatorBridge.activateInput(input.intValue!)
        }
    }
    
    public func gameController(_ gameController: GameController, didDeactivate input: Input)
    {
        guard let input = self.mappedInput(for: input), input.type == .game(self.gameType) else { return }
        
        self.deltaCore.emulatorBridge.deactivateInput(input.intValue!)
    }
    
    private func mappedInput(for input: Input) -> Input?
    {
        guard let standardInput = StandardGameControllerInput(input: input) else { return input }
        
        let mappedInput = standardInput.input(for: self.gameType)
        return mappedInput
    }
}

private extension EmulatorCore
{
    func runGameLoop()
    {
        let emulationQueue = DispatchQueue(label: "com.rileytestut.DeltaCore.emulationQueue", qos: .userInitiated)
        emulationQueue.async {
            
            let screenRefreshRate = 1.0 / 60.0
            
            var emulationTime = Thread.absoluteSystemTime
            var counter = 0.0
            
            while true
            {
                let frameDuration = self.deltaCore.frameDuration / self.rate
                
                if self.rate != self.previousRate
                {
                    Thread.setRealTimePriority(withPeriod: frameDuration)
                    
                    self.previousRate = self.rate
                    
                    // Reset counter
                    counter = 0
                }
                
                if counter >= screenRefreshRate
                {
                    self.runFrame(renderGraphics: true)
                    
                    // Reset counter
                    counter = 0
                }
                else
                {
                    // No need to render graphics more than once per screen refresh rate
                    self.runFrame(renderGraphics: false)
                }
                
                counter += frameDuration
                emulationTime += frameDuration
                
                let currentTime = Thread.absoluteSystemTime
                
                // The number of frames we need to skip to keep in sync
                let framesToSkip = Int((currentTime - emulationTime) / frameDuration)
                
                if framesToSkip > 0
                {
                    // Only actually skip frames if we're running at normal speed
                    if self.rate == 1.0
                    {
                        for _ in 0 ..< framesToSkip
                        {
                            // "Skip" frames by running them without rendering graphics
                            self.runFrame(renderGraphics: false)
                        }
                    }
                    
                    emulationTime = currentTime
                }
                
                // Prevent race conditions
                let state = self._state
                
                if self.previousState != state
                {
                    self.emulationSemaphore.signal()
                    
                    self.previousState = state
                }
                
                if state != .running
                {
                    break
                }
                
                Thread.realTimeWait(until: emulationTime)
            }
            
        }
    }
    
    func runFrame(renderGraphics: Bool)
    {
        self.deltaCore.emulatorBridge.runFrame()
        
        if renderGraphics
        {
            self.videoManager.didUpdateVideoBuffer()
        }
        
        for semaphore in self.reactivateInputsSemaphores
        {
            semaphore.signal()
        }
        
        self.updateHandler?(self)
    }
}
