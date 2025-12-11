using UnityEngine;
using System.Collections;
using System.Collections.Generic;

public class MissionLogicScript : MonoBehaviour
{
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
                Debug.Log(missionName + " " + i.ToString());
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
    public GameObject completedMissionMenuPrefab;
    public GameObject completedMissionMenu;
    public PlayerDataScript.Salvage totalSalvage;
    public Dictionary<string, int> cloneProgressAtStart;

    IEnumerator WaitForGameController()
    {
        while (missionName == null || endHub == null)
        {
            yield return null;
        }
        PlayerDataScript playerData = PlayerDataScript.Instance;
        // save snapshot of current clone progress
        Dictionary<string, PlayerDataScript.CloneData> allCloneData = playerData.allCloneData;
        foreach (string cloneMission in allCloneData.Keys)
        {
            PlayerDataScript.CloneData cloneData = allCloneData[cloneMission];
            cloneProgressAtStart.Add(cloneMission, cloneData.currentProgress);
        }
        int missionSeed = playerData.randomSeed + playerData.turns + missionName.GetHashCode();
        Random.InitState(missionSeed);
        NextLevel();
    }

    void Start()
    {
        gameController = GameObject.Find("Game Controller");
        gameControllerScript = gameController.GetComponent<GameControllerScript>();
        levelPrefab = Resources.Load<GameObject>("Prefabs/Level");
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
        // to-do - instantiate completed mission ui
        // to-do - reward accumulated salvage from completed clone runs
        // to-do - add new clone from this completed run
        gameControllerScript.EnterHub(endHub);
    }
}
