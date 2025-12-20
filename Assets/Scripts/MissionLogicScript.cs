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
            MonoBehaviour[] allMonoBehaviours = level.GetComponentsInChildren<MonoBehaviour>();
            foreach (MonoBehaviour monoBehavior in allMonoBehaviours)
            {
                monoBehavior.StopAllCoroutines();
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
}
