using UnityEngine;
using System.Collections;
using System.Collections.Generic;

public class MissionLogicScript : MonoBehaviour
{
    public static MissionLogicScript Instance { get; private set; }
    public GameObject gameController;
    public GameControllerScript gameControllerScript;
    public string missionName;
    public int missionLength;
    public Color[] missionColors = new Color[6];
    public Color[] interfaceColors = new Color[6];
    public string endHub;
    public List<string> levelNames
    {
        get
        {
            List<string> nameList = new List<string>();
            for (int i = 0; i < missionLength; i++)
            {
                nameList.Add(missionName + " " + i.ToString());
            }
            return nameList;
        }
    }
    public int currentLevel;
    public string currentLevelName
    {
        get
        {
            return levelNames[currentLevel];
        }
    }
    public GameObject levelPrefab;
    public GameObject level;
    public GameObject missionCompletionScreenPrefab;
    public GameObject missionCompletionScreen;
    public GameObject defeatScreenPrefab;
    public GameObject defeatScreen;
    public int totalTurns;
    public PlayerDataScript.Salvage totalSalvage;
    public int totalKills;
    public int totalUsedSkills;
    public int totalOutgoingDamage;
    public int totalIncomingDamage;

    void Awake()
    {
        if (Instance == null)
        {
            Instance = this;
        }
        else
        {
            Destroy(this.gameObject);
        }
        // hardcoded colors for prototype
        string[] missionHexColors = new string[6]{
            "#f5f8d4",
            "#d6da7b",
            "#bec761",
            "#aaae56",
            "#969446",
            "#767253"
        };
        string[] interfaceHexColors = new string[6]{
            "#fef1e8",
            "#f3a56c",
            "#ee9159",
            "#d57f4f",
            "#af6e50",
            "#845d4c"
        };
        for (int i = 0; i < 6; i++)
        {
            Color newColor;
            if (ColorUtility.TryParseHtmlString(missionHexColors[i], out newColor))
            {
                missionColors[i] = newColor;
            }
            else
            {
                Debug.LogError("invalid hex color");
            }
        }
        for (int i = 0; i < 6; i++)
        {
            Color newColor;
            if (ColorUtility.TryParseHtmlString(interfaceHexColors[i], out newColor))
            {
                interfaceColors[i] = newColor;
            }
            else
            {
                Debug.LogError("invalid hex color");
            }
        }
    }

    void OnDestroy()
    {
        if (Instance == this)
        {
            Instance = null;
        }
    }

    IEnumerator WaitForGameController()
    {
        while (missionName == null || endHub == null)
        {
            yield return null;
        }
        PlayerDataScript playerData = PlayerDataScript.Instance;
        int missionSeed = playerData.randomSeed + playerData.turns + missionName.GetHashCode();
        Random.InitState(missionSeed);
        NextLevel();
    }

    void Start()
    {
        gameController = GameObject.Find("Game Controller");
        gameControllerScript = gameController.GetComponent<GameControllerScript>();
        levelPrefab = Resources.Load<GameObject>("Prefabs/Level");
        missionCompletionScreenPrefab = Resources.Load<GameObject>("Prefabs/Mission Completion Screen");
        defeatScreenPrefab = Resources.Load<GameObject>("Prefabs/Defeat Screen");
        currentLevel = 0;
        totalSalvage = new PlayerDataScript.Salvage();
        StartCoroutine(WaitForGameController());
    }
    
    public void NextLevel()
    {
        if (level != null)
        {
            GameObject player = level.transform.Find("Player").gameObject;
            PlayerDataScript.Instance.BuildDataFromPlayer(player);
#if !UNITY_WEBGL || UNITY_EDITOR
            PlayerDataScript.Instance.SavePlayerData("Autosave");
#endif
            MonoBehaviour[] allMonoBehaviours = level.GetComponentsInChildren<MonoBehaviour>();
            foreach (MonoBehaviour monoBehavior in allMonoBehaviours)
            {
                if (monoBehavior != null)
                {
                    monoBehavior.StopAllCoroutines();
                }
            }
            DestroyImmediate(level);
        }
        if (currentLevel < missionLength)
        {
            level = Instantiate(levelPrefab);
        }
        else
        {
            MissionEnd();
        }
    }

    public void MissionEnd()
    {
        missionCompletionScreen = Instantiate(missionCompletionScreenPrefab, this.transform);
    }

    public void MissionDefeat()
    {
        MonoBehaviour[] allMonoBehaviours = level.GetComponentsInChildren<MonoBehaviour>();
        foreach (MonoBehaviour monoBehavior in allMonoBehaviours)
        {
            if (monoBehavior != null)
            {
                monoBehavior.StopAllCoroutines();
            }
        }
        DestroyImmediate(level);
        defeatScreen = Instantiate(defeatScreenPrefab, this.transform);
    }
}
