//
//  DatabaseManager.swift
//  Delta
//
//  Created by Riley Testut on 10/4/15.
//  Copyright © 2015 Riley Testut. All rights reserved.
//

import CoreData

// Workspace
import Roxas
import DeltaCore

// Pods
import FileMD5Hash

class DatabaseManager
{
    static let sharedManager = DatabaseManager()
    
    let managedObjectContext: NSManagedObjectContext
    
    class var databaseDirectoryURL: NSURL
    {
        let documentsDirectoryURL: NSURL
        
        if UIDevice.currentDevice().userInterfaceIdiom == .TV
        {
            documentsDirectoryURL = NSFileManager.defaultManager().URLsForDirectory(NSSearchPathDirectory.CachesDirectory, inDomains: NSSearchPathDomainMask.UserDomainMask).first!
        }
        else
        {
            documentsDirectoryURL = NSFileManager.defaultManager().URLsForDirectory(NSSearchPathDirectory.DocumentDirectory, inDomains: NSSearchPathDomainMask.UserDomainMask).first!
        }
        
        let databaseDirectoryURL = documentsDirectoryURL.URLByAppendingPathComponent("Database")
        
        
        do
        {
            try NSFileManager.defaultManager().createDirectoryAtURL(databaseDirectoryURL, withIntermediateDirectories: true, attributes: nil)
        }
        catch
        {
            print(error)
        }
        
        return databaseDirectoryURL
    }
    
    class var gamesDirectoryURL: NSURL
    {
        let gamesDirectoryURL = DatabaseManager.databaseDirectoryURL.URLByAppendingPathComponent("Games")
        
        do
        {
            try NSFileManager.defaultManager().createDirectoryAtURL(gamesDirectoryURL, withIntermediateDirectories: true, attributes: nil)
        }
        catch
        {
            print(error)
        }
        
        return gamesDirectoryURL
    }
    
    private let privateManagedObjectContext: NSManagedObjectContext
    private let validationManagedObjectContext: NSManagedObjectContext
    
    // MARK: - Initialization -
    /// Initialization
    
    private init()
    {
        let modelURL = NSBundle.mainBundle().URLForResource("Model", withExtension: "momd")
        let managedObjectModel = NSManagedObjectModel(contentsOfURL: modelURL!)
        let persistentStoreCoordinator = NSPersistentStoreCoordinator(managedObjectModel: managedObjectModel!)
        
        self.privateManagedObjectContext = NSManagedObjectContext(concurrencyType: .PrivateQueueConcurrencyType)
        self.privateManagedObjectContext.persistentStoreCoordinator = persistentStoreCoordinator
        self.privateManagedObjectContext.mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy
        
        self.managedObjectContext = NSManagedObjectContext(concurrencyType: .MainQueueConcurrencyType)
        self.managedObjectContext.parentContext = self.privateManagedObjectContext
        self.managedObjectContext.mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy
        
        self.validationManagedObjectContext = NSManagedObjectContext(concurrencyType: .PrivateQueueConcurrencyType)
        self.validationManagedObjectContext.parentContext = self.managedObjectContext
        self.validationManagedObjectContext.mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy
        
        NSNotificationCenter.defaultCenter().addObserver(self, selector: Selector("managedObjectContextDidSave:"), name: NSManagedObjectContextDidSaveNotification, object: nil)
    }
    
    func startWithCompletion(completionBlock: ((performingMigration: Bool) -> Void)?)
    {
        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0)) {
            
            let storeURL = DatabaseManager.databaseDirectoryURL.URLByAppendingPathComponent("Delta.sqlite")

            let options = [NSMigratePersistentStoresAutomaticallyOption: true, NSInferMappingModelAutomaticallyOption: true]
            
            var performingMigration = false
            
            if let sourceMetadata = try? NSPersistentStoreCoordinator.metadataForPersistentStoreOfType(NSSQLiteStoreType, URL: storeURL, options: options),
                managedObjectModel = self.privateManagedObjectContext.persistentStoreCoordinator?.managedObjectModel
            {
                performingMigration = !managedObjectModel.isConfiguration(nil, compatibleWithStoreMetadata: sourceMetadata)
            }
            
            do
            {
                try self.privateManagedObjectContext.persistentStoreCoordinator?.addPersistentStoreWithType(NSSQLiteStoreType, configuration: nil, URL: storeURL, options: options)
            }
            catch let error as NSError
            {
                if error.code == NSMigrationMissingSourceModelError
                {
                    print("Migration failed. Try deleting \(storeURL)")
                }
                else
                {
                    print(error)
                }
                
                abort()
            }
            
            if let completionBlock = completionBlock
            {
                completionBlock(performingMigration: performingMigration)
            }
        }
    }
    
    // MARK: - Importing -
    /// Importing
    
    func importGamesAtURLs(URLs: [NSURL], withCompletion completion: ([String] -> Void)?)
    {
        let managedObjectContext = self.backgroundManagedObjectContext()
        managedObjectContext.performBlock() {
            
            var identifiers: [String] = []
            
            for URL in URLs
            {
                let identifier = FileHash.sha1HashOfFileAtPath(URL.path) as String
                
                var filename = identifier
                if let pathExtension = URL.pathExtension
                {
                    filename += "." + pathExtension
                }
                
                let game = Game.insertIntoManagedObjectContext(managedObjectContext)
                game.name = URL.URLByDeletingPathExtension?.lastPathComponent ?? NSLocalizedString("Game", comment: "")
                game.identifier = identifier
                game.filename = filename
                
                if let pathExtension = URL.pathExtension,
                    gameCollection = GameCollection.gameSystemCollectionForPathExtension(pathExtension, inManagedObjectContext: managedObjectContext)
                {
                    game.typeIdentifier = gameCollection.identifier
                    game.gameCollections.insert(gameCollection)
                }
                else
                {
                    game.typeIdentifier = kUTTypeDeltaGame as String
                }
                
                do
                {
                    try NSFileManager.defaultManager().moveItemAtURL(URL, toURL: DatabaseManager.gamesDirectoryURL.URLByAppendingPathComponent(game.identifier + ".smc"))
                    
                    identifiers.append(game.identifier)
                }
                catch
                {
                    game.managedObjectContext?.deleteObject(game)
                }
                
            }
            
            do
            {
                try managedObjectContext.save()
            }
            catch let error as NSError
            {
                print("Failed to save import context:", error)
                
                identifiers.removeAll()
            }
            
            if let completion = completion
            {
                completion(identifiers)
            }
        }
        
        
    }
    
    // MARK: - Background Contexts -
    /// Background Contexts
    
    func backgroundManagedObjectContext() -> NSManagedObjectContext
    {
        let managedObjectContext = NSManagedObjectContext(concurrencyType: .PrivateQueueConcurrencyType)
        managedObjectContext.parentContext = self.validationManagedObjectContext
        managedObjectContext.mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy
        
        return managedObjectContext
    }
}

private extension DatabaseManager
{
    // MARK: - Saving -
    
    private func save()
    {
        let backgroundTaskIdentifier = RSTBeginBackgroundTask("Save Database Task")
        
        self.validationManagedObjectContext.performBlockAndWait {
            
            do
            {
                try self.validationManagedObjectContext.save()
            }
            catch let error as NSError
            {
                print("Failed to save validation context:", error)
            }
            
            
            // Update main managed object context
            self.managedObjectContext.performBlockAndWait() {
                
                do
                {
                    try self.managedObjectContext.save()
                }
                catch let error as NSError
                {
                    print("Failed to save main context:", error)
                }
                
                
                // Save to disk
                self.privateManagedObjectContext.performBlock() {
                    
                    do
                    {
                        try self.privateManagedObjectContext.save()
                    }
                    catch let error as NSError
                    {
                        print("Failed to save private context to disk:", error)
                    }
                    
                    RSTEndBackgroundTask(backgroundTaskIdentifier)
                    
                }
                
            }
            
        }
    }
    
    // MARK: - Notifications -
    
    dynamic func managedObjectContextDidSave(notification: NSNotification)
    {
        guard let managedObjectContext = notification.object as? NSManagedObjectContext where managedObjectContext.parentContext == self.validationManagedObjectContext else { return }
        
        self.save()
    }
    
}
