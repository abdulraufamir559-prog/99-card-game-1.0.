require "import"
import "android.app.*"
import "android.os.*"
import "android.widget.*"
import "android.view.*"
import "android.text.InputFilter"
import "android.media.MediaPlayer"
import "android.speech.tts.TextToSpeech"
import "android.content.DialogInterface" 
import "android.content.Intent" 
import "android.net.Uri"         
import "java.util.Locale"
import "java.net.URLEncoder"
import "com.androlua.Http" -- Required for Firebase Online Database requests

-- SharedPreferences for saving user data locally (Backup)
local activity = activity
local preferences = activity.getSharedPreferences("99CardGamePrefs", activity.MODE_PRIVATE)
local isFirstTime = preferences.getBoolean("isFirstTime", true)

-- Firebase Database Configuration
local FIREBASE_URL = "https://card-game-f8aa2-default-rtdb.firebaseio.com/"

-- Global Variables for Audio and TTS Engine
local currentMusicPlayer = nil
local ttsEngine = nil

-- Absolute Audio File Paths
local MENU_MUSIC_PATH = "/storage/emulated/0/A.K Mods/Free Music Generator/EDM_20260504_192629.mp3"
local GAME_ABOUT_MUSIC_PATH = "/storage/emulated/0/A.K Mods/Free Music Generator/Techno_20260504_175527.mp3"
local SOUND_SHUFFLE = "/storage/emulated/0/ApkEditor/tmp/card_shuffle.mp3"
local SOUND_CARD_PUT = "/storage/emulated/0/ApkEditor/tmp/card_put.mp3"

local audioManager = activity.getSystemService("audio")

-- ==========================================
-- FIREBASE DATABASE FUNCTIONS
-- ==========================================
-- Function to save or update player data to Firebase Online Cloud
local function syncDataToFirebase(username, wins, losses)
  -- Sanitizing username for Firebase path (removes spaces/special dots)
  local safeName = username:gsub("[%s%.%#%$%[%]]", "_")
  local targetUrl = FIREBASE_URL .. "players/" .. safeName .. ".json"
  
  -- Preparing JSON payload data
  local jsonPayload = string.format('{"username":"%s", "wins":%d, "losses":%d, "lastLogin":"%s"}', 
    username, wins, losses, os.date("%Y-%m-%d %H:%M:%S"))
  
  -- Async HTTP PUT request to Firebase REST API
  Http.put(targetUrl, jsonPayload, function(code, body)
    if code == 200 or code == 201 then
      print("☁️ Data synced online to Firebase successfully!")
    else
      print("⚠️ Online Sync Failed (Code: " .. tostring(code) .. ")")
    end
  end)
end

-- ==========================================
-- TEXT-TO-SPEECH (TTS) INITIALIZATION
-- ==========================================
local function initTTS()
  if ttsEngine == nil then
    ttsEngine = TextToSpeech(activity, TextToSpeech.OnInitListener({
      onInit = function(status)
        if status == TextToSpeech.SUCCESS then
          ttsEngine.setLanguage(Locale.US)
        end
      end
    }))
  end
end
initTTS()

local function speak(text)
  if ttsEngine ~= nil then
    ttsEngine.speak(text, TextToSpeech.QUEUE_FLUSH, nil)
  end
end

-- ==========================================
-- GAMEPLAY STATE & VARIABLES
-- ==========================================
local runningTotal = 0
local isPlayerTurn = true
local playerHand = {}
local computerHand = {}
local deck = {}
local txtTotalScore, txtGameStatus, cardsContainer

local function createDeck()
  deck = {}
  local suits = {"♠", "♥", "♦", "♣"}
  local values = {"2", "3", "4", "5", "6", "7", "8", "9", "10", "J", "Q", "K", "A"}
  for _, suit in ipairs(suits) do
    for _, val in ipairs(values) do
      table.insert(deck, {value = val, suit = suit})
    end
  end
  math.randomseed(os.time())
  for i = #deck, 2, -1 do
    local j = math.random(i)
    deck[i], deck[j] = deck[j], deck[i]
  end
end

local function drawCard()
  if #deck == 0 then createDeck() end
  return table.remove(deck, 1)
end

local showMainMenu
local updateUI
local computerTurn
local checkGameOver

local function playSoundEffect(filePath)
  local success, err = pcall(function()
    local mp = MediaPlayer()
    mp.setDataSource(filePath)
    mp.prepare()
    mp.start()
    mp.setOnCompletionListener({
      onCompletion = function(mediaPlayer)
        mediaPlayer.release() 
      end
    })
  end)
  if not success then
    print("Audio Sfx Error: File path incorrect or permission denied.")
  end
end

local function applyCardLogic(cardValue, choice)
  if cardValue == "A" then
    runningTotal = runningTotal + choice
  elseif cardValue == "2" then
    if runningTotal < 50 then
      runningTotal = runningTotal * 2
    else
      if runningTotal % 2 == 0 then
        runningTotal = math.floor(runningTotal / 2)
      else
        runningTotal = runningTotal * 2
      end
    end
  elseif cardValue == "3" or cardValue == "4" or cardValue == "5" or cardValue == "6" or cardValue == "7" or cardValue == "8" then
    runningTotal = runningTotal + tonumber(cardValue)
  elseif cardValue == "9" then
    -- +0 Points (Pass)
  elseif cardValue == "10" then
    runningTotal = runningTotal + choice
    if runningTotal < 0 then runningTotal = 0 end
  elseif cardValue == "K" or cardValue == "Q" then
    runningTotal = runningTotal + 10
  elseif cardValue == "J" then
    runningTotal = runningTotal + 10
  end
end

-- Match Result Checker (With Firebase Data Cloud Syncing Integration)
checkGameOver = function(lastPlayer)
  if runningTotal > 99 then
    txtTotalScore.setText("Total: " .. runningTotal)
    local msg = ""
    
    -- Local scores load kar rahe hain taake unhein update karke Firebase pe bhej sakein
    local currentName = preferences.getString("userName", "Player")
    local wins = preferences.getInt("userWins", 0)
    local losses = preferences.getInt("userLosses", 0)
    local editor = preferences.edit()

    if lastPlayer == "Player" then
      msg = "Game Over! You exceeded 99. Computer Wins!"
      txtGameStatus.setText("🔴 " .. msg)
      losses = losses + 1
      editor.putInt("userLosses", losses)
    else
      msg = "Congratulations! Computer exceeded 99. You Win!"
      txtGameStatus.setText("🎉 " .. msg)
      wins = wins + 1
      editor.putInt("userWins", wins)
    end
    
    editor.apply() -- Local save
    syncDataToFirebase(currentName, wins, losses) -- Instant Online Firebase Cloud sync
    
    speak(msg)
    cardsContainer.removeAllViews() 
    return true
  end
  return false
end

-- ==========================================
-- BACKGROUND MUSIC MANAGEMENT
-- ==========================================
local function playMusic(filePath, isLooping)
  if currentMusicPlayer ~= nil then
    pcall(function()
      if currentMusicPlayer.isPlaying() then currentMusicPlayer.stop() end
      currentMusicPlayer.release()
    end)
    currentMusicPlayer = nil
  end

  local success, err = pcall(function()
    currentMusicPlayer = MediaPlayer()
    currentMusicPlayer.setDataSource(filePath)
    currentMusicPlayer.setLooping(isLooping)
    currentMusicPlayer.prepare()
    currentMusicPlayer.start()
  end)
  if not success then
    print("Music System Error: Track initialization failed.")
    currentMusicPlayer = nil
  end
end

local function stopAllMusic()
  if currentMusicPlayer ~= nil then
    pcall(function()
      if currentMusicPlayer.isPlaying() then currentMusicPlayer.stop() end
      currentMusicPlayer.release()
    end)
    currentMusicPlayer = nil
  end
end

-- ==========================================
-- COMPUTER AUTOMATED TURN (EXACT 2 SEC DELAY)
-- ==========================================
computerTurn = function()
  if checkGameOver("Player") then return end
  
  txtGameStatus.setText("🤖 Computer is thinking...")
  
  Handler().postDelayed(Runnable({
    run = function()
      local cardIndex = 1
      local selectedCard = table.remove(computerHand, cardIndex)
      local choice = 0
      
      if selectedCard.value == "A" then
        if runningTotal + 11 > 99 then choice = 1 else choice = 11 end
      elseif selectedCard.value == "10" then
        if runningTotal + 10 > 99 then choice = -10 else choice = 10 end
      end
      
      playSoundEffect(SOUND_CARD_PUT)
      applyCardLogic(selectedCard.value, choice)
      table.insert(computerHand, drawCard()) 
      
      txtTotalScore.setText("Total: " .. runningTotal)
      
      local ttsText = "Computer played " .. selectedCard.value .. ". Total is " .. runningTotal
      speak(ttsText)
      
      if not checkGameOver("Computer") then
        if selectedCard.value == "J" then
          txtGameStatus.setText("⚡ Computer played Jack! Extra Turn for Computer.")
          speak("Computer gets an extra turn")
          computerTurn() 
        else
          isPlayerTurn = true
          txtGameStatus.setText("🟢 Your Turn! Choose a card.")
          updateUI() 
        end
      end
    end
  }), 2000)
end

-- ==========================================
-- CHOICE DIALOGS POP-UPS (FOR ACE AND 10)
-- ==========================================
local function showChoiceDialog(cardValue, callback)
  local dialog = AlertDialog.Builder(activity)
  dialog.setCancelable(false)
  
  if cardValue == "A" then
    dialog.setTitle("Ace Card Choice")
    dialog.setMessage("Do you want to add 1 or 11 to the pool score?")
    dialog.setPositiveButton("Add 11", DialogInterface.OnClickListener({
      onClick = function(d, w) callback(11) end
    }))
    dialog.setNegativeButton("Add 1", DialogInterface.OnClickListener({
      onClick = function(d, w) callback(1) end
    }))
  elseif cardValue == "10" then
    dialog.setTitle("10 Card Choice")
    dialog.setMessage("Do you want to Add 10 or Subtract 10 from the pool score?")
    dialog.setPositiveButton("Add 10", DialogInterface.OnClickListener({
      onClick = function(d, w) callback(10) end
    }))
    dialog.setNegativeButton("Subtract 10", DialogInterface.OnClickListener({
      onClick = function(d, w) callback(-10) end
    }))
  end
  dialog.show()
end

-- ==========================================
-- MAIN GAMEPLAY SCREEN & LOOP Setup
-- ==========================================
local function startNewGame()
  runningTotal = 0
  isPlayerTurn = true
  createDeck()
  
  playerHand = {}
  computerHand = {}
  for i = 1, 5 do
    table.insert(playerHand, drawCard())
    table.insert(computerHand, drawCard())
  end

  local gameLayout = LinearLayout(activity)
  gameLayout.setOrientation(LinearLayout.VERTICAL)
  gameLayout.setGravity(Gravity.CENTER)
  gameLayout.setPadding(40, 40, 40, 40)

  txtTotalScore = TextView(activity)
  txtTotalScore.setText("Total: " .. runningTotal)
  txtTotalScore.setTextSize(36)
  txtTotalScore.setGravity(Gravity.CENTER)
  txtTotalScore.setPadding(0, 0, 0, 20)
  gameLayout.addView(txtTotalScore)

  txtGameStatus = TextView(activity)
  txtGameStatus.setText("🟢 Your Turn! Play a card.")
  txtGameStatus.setTextSize(16)
  txtGameStatus.setGravity(Gravity.CENTER)
  txtGameStatus.setPadding(0, 0, 0, 40)
  gameLayout.addView(txtGameStatus)

  cardsContainer = LinearLayout(activity)
  cardsContainer.setOrientation(LinearLayout.HORIZONTAL)
  cardsContainer.setGravity(Gravity.CENTER)
  gameLayout.addView(cardsContainer)

  updateUI = function()
    cardsContainer.removeAllViews()
    if not isPlayerTurn then return end

    for i, card in ipairs(playerHand) do
      local btnCard = Button(activity)
      btnCard.setText(card.value .. card.suit)
      btnCard.setPadding(10, 10, 10, 10)
      
      btnCard.setOnClickListener(function()
        if not isPlayerTurn then return end
        
        local playedCard = card
        
        local function executeTurn(chosenValue)
          table.remove(playerHand, i)
          playSoundEffect(SOUND_CARD_PUT)
          applyCardLogic(playedCard.value, chosenValue)
          table.insert(playerHand, drawCard()) 
          
          txtTotalScore.setText("Total: " .. runningTotal)
          
          local ttsText = "You played " .. playedCard.value .. ". Total is " .. runningTotal
          speak(ttsText)
          
          if not checkGameOver("Player") then
            if playedCard.value == "J" then
              txtGameStatus.setText("⚡ You played Jack! You get an Extra Turn.")
              speak("You get an extra turn")
              updateUI() 
            else
              isPlayerTurn = false
              updateUI() 
              computerTurn() 
            end
          end
        end

        if playedCard.value == "A" or playedCard.value == "10" then
          showChoiceDialog(playedCard.value, executeTurn)
        else
          executeTurn(0) 
        end

      end)
      cardsContainer.addView(btnCard)
    end
  end

  updateUI() 

  local btnLeave = Button(activity)
  btnLeave.setText("Leave Game")
  btnLeave.setPadding(0, 40, 0, 0)
  btnLeave.setOnClickListener(function() showMainMenu() end)
  gameLayout.addView(btnLeave)

  activity.setContentView(gameLayout)
  speak("99 Card Game Started. Your turn first.")
end

-- ==========================================
-- SYSTEM PANEL NAVIGATION VIEWS
-- ==========================================
local function showSettingsScreen()
  local setLayout = LinearLayout(activity)
  setLayout.setOrientation(LinearLayout.VERTICAL)
  setLayout.setGravity(Gravity.CENTER)
  setLayout.setPadding(50, 50, 50, 50)

  local title = TextView(activity)
  title.setText("Settings - Volume")
  title.setTextSize(22)
  title.setPadding(0, 0, 0, 40)
  setLayout.addView(title)

  local seekBar = SeekBar(activity)
  local maxVol = audioManager.getStreamMaxVolume(3)
  local currentVol = audioManager.getStreamVolume(3)
  seekBar.setMax(maxVol)
  seekBar.setProgress(currentVol)
  seekBar.setPadding(30, 20, 30, 40)
  
  seekBar.setOnSeekBarChangeListener({
    onProgressChanged = function(sb, progress, fromUser)
      audioManager.setStreamVolume(3, progress, 0)
    end
  })
  setLayout.addView(seekBar)

  local btnBack = Button(activity)
  btnBack.setText("Back to Menu")
  btnBack.setOnClickListener(function() showMainMenu() end)
  setLayout.addView(btnBack)

  activity.setContentView(setLayout)
end

local function showAboutScreen()
  playMusic(GAME_ABOUT_MUSIC_PATH, true)

  local aboutLayout = LinearLayout(activity)
  aboutLayout.setOrientation(LinearLayout.VERTICAL)
  aboutLayout.setGravity(Gravity.TOP)
  aboutLayout.setPadding(40, 40, 40, 40)

  local scrollView = ScrollView(activity)
  local scrollContent = LinearLayout(activity)
  scrollContent.setOrientation(LinearLayout.VERTICAL)

  local aboutTitle = TextView(activity)
  aboutTitle.setText("About & Game Guide")
  aboutTitle.setTextSize(24)
  aboutTitle.setGravity(Gravity.CENTER)
  aboutTitle.setPadding(0, 0, 0, 30)
  scrollContent.addView(aboutTitle)

  local guideText = TextView(activity)
  guideText.setText([[99 DYNAMIC CALCULATION RULES:
1. Ace: Multi-Choice to Add 1 or 11 points.
2. 2 Multiplier: If Total < 50, Total x 2. If >= 50, Even Total / 2, Odd Total x 2.
3. 3 to 8: Adds absolute face value directly.
4. 9: Safe Card (Passes turn with +0 points).
5. 10: Multi-Choice to Add 10 or Subtract 10 points.
6. King / Queen: Force adds 10 points.
7. Jack: Adds 10 points & keeps the active turn alive (Extra Chance).]])
  guideText.setTextSize(14)
  guideText.setPadding(0, 0, 20, 30)
  scrollContent.addView(guideText)

  local btnWhatsApp = Button(activity)
  btnWhatsApp.setText("Join My WhatsApp Group")
  btnWhatsApp.setPadding(0, 20, 0, 20)
  btnWhatsApp.setOnClickListener(function()
    local url = "https://chat.whatsapp.com/Cq9qmBKXpjP3t7Jy7oPtWk"
    local intent = Intent(Intent.ACTION_VIEW)
    intent.setData(Uri.parse(url))
    activity.startActivity(intent) 
  end)
  scrollContent.addView(btnWhatsApp)

  local btnFeedback = Button(activity)
  btnFeedback.setText("Send Feedback to Developer")
  btnFeedback.setPadding(0, 20, 0, 20)
  btnFeedback.setOnClickListener(function()
    local phoneNumber = "92323234391" 
    local defaultMsg = "Hello Developer, I want to give feedback about 99 Card Game: "
    local encodedMsg = URLEncoder.encode(defaultMsg, "UTF-8")
    local whatsappUrl = "https://api.whatsapp.com/send?phone=" .. phoneNumber .. "&text=" .. encodedMsg
    
    local intent = Intent(Intent.ACTION_VIEW)
    intent.setData(Uri.parse(whatsappUrl))
    activity.startActivity(intent) 
  end)
  scrollContent.addView(btnFeedback)

  local btnBack = Button(activity)
  btnBack.setText("Back to Menu")
  btnBack.setPadding(0, 30, 0, 0)
  btnBack.setOnClickListener(function() showMainMenu() end)
  scrollContent.addView(btnBack)

  scrollView.addView(scrollContent)
  aboutLayout.addView(scrollView)
  activity.setContentView(aboutLayout)
end

function showMainMenu()
  playMusic(MENU_MUSIC_PATH, true)

  local currentName = preferences.getString("userName", "Player")
  local wins = preferences.getInt("userWins", 0)
  local losses = preferences.getInt("userLosses", 0)
  
  local mainLayout = LinearLayout(activity)
  mainLayout.setOrientation(LinearLayout.VERTICAL)
  mainLayout.setGravity(Gravity.CENTER)
  mainLayout.setPadding(40, 40, 40, 40)

  local titleView = TextView(activity)
  titleView.setText("99 card game")
  titleView.setTextSize(28)
  titleView.setGravity(Gravity.CENTER)
  titleView.setPadding(0, 0, 0, 50)
  mainLayout.addView(titleView)

  local btnProfile = Button(activity)
  -- Main Menu Profile button par hi live sync score dikhega
  btnProfile.setText(string.format("Profile (%s) - W: %d | L: %d", currentName, wins, losses))
  btnProfile.setOnClickListener(function() 
    print("Player: " .. currentName .. " | Wins: " .. wins .. " | Losses: " .. losses) 
  end)
  mainLayout.addView(btnProfile)

  local btnGameMenu = Button(activity)
  btnGameMenu.setText("99 Card Game")
  btnGameMenu.setOnClickListener(function()
    stopAllMusic()                 
    playSoundEffect(SOUND_SHUFFLE) 
    startNewGame()                 
  end)
  mainLayout.addView(btnGameMenu)

  local btnSettings = Button(activity)
  btnSettings.setText("Settings")
  btnSettings.setOnClickListener(function() showSettingsScreen() end)
  mainLayout.addView(btnSettings)

  local btnMoreOptions = Button(activity)
  btnMoreOptions.setText("More Options")
  mainLayout.addView(btnMoreOptions)

  local btnAbout = Button(activity)
  btnAbout.setText("About")
  btnAbout.setOnClickListener(function() showAboutScreen() end)
  mainLayout.addView(btnAbout)

  local btnExit = Button(activity)
  btnExit.setText("Exit")
  btnExit.setOnClickListener(function()
    stopAllMusic()
    activity.finish()
  end)
  mainLayout.addView(btnExit)

  activity.setContentView(mainLayout)
end

local function showNameInputScreen()
  local nameLayout = LinearLayout(activity)
  nameLayout.setOrientation(LinearLayout.VERTICAL)
  nameLayout.setGravity(Gravity.CENTER)
  nameLayout.setPadding(40, 40, 40, 40)

  local infoText = TextView(activity)
  infoText.setText("Please enter your name:")
  infoText.setTextSize(18)
  infoText.setPadding(0, 0, 0, 20)
  nameLayout.addView(infoText)

  local inputField = EditText(activity)
  inputField.setHint("Enter Name (Max 17 chars)")
  local filters = luajava.createArray("android.text.InputFilter", {InputFilter.LengthFilter(17)})
  inputField.setFilters(filters)
  nameLayout.addView(inputField)

  local btnGetStarted = Button(activity)
  btnGetStarted.setText("Get Started")
  btnGetStarted.setOnClickListener(function()
    local enteredName = tostring(inputField.getText())
    if enteredName == "" then print("Name cannot be empty!") return end
    if string.find(enteredName, "[^%w%s]") then print("Special characters not allowed!") return end

    local editor = preferences.edit()
    editor.putString("userName", enteredName)
    editor.putInt("userWins", 0)    -- Initializing local wins tracker
    editor.putInt("userLosses", 0)  -- Initializing local losses tracker
    editor.putBoolean("isFirstTime", false)
    editor.apply()
    
    -- Sync initial profile to Firebase immediately
    syncDataToFirebase(enteredName, 0, 0)
    
    showMainMenu()
  end)
  nameLayout.addView(btnGetStarted)
  activity.setContentView(nameLayout)
end

local function showWelcomeScreen()
  local welcomeLayout = LinearLayout(activity)
  welcomeLayout.setOrientation(LinearLayout.VERTICAL)
  welcomeLayout.setGravity(Gravity.CENTER)
  welcomeLayout.setPadding(40, 40, 40, 40)

  local longTextView = TextView(activity)
  longTextView.setText([[Welcome to the official 99 Card Game platform. Your progress is saved locally and synced online.]])
  longTextView.setTextSize(16)
  longTextView.setPadding(0, 0, 0, 40)
  welcomeLayout.addView(longTextView)

  local btnNext = Button(activity)
  btnNext.setText("Next")
  btnNext.setOnClickListener(function() showNameInputScreen() end)
  welcomeLayout.addView(btnNext)
  activity.setContentView(welcomeLayout)
end

function onDestroy()
  stopAllMusic()
  if ttsEngine ~= nil then
    ttsEngine.stop()
    ttsEngine.shutdown()
  end
end

if isFirstTime then showWelcomeScreen() else showMainMenu() end