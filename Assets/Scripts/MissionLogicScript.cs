using UnityEngine;
using System.Collections.Generic;

public class MissionLogicScript : MonoBehaviour
{
    public string missionName; // to be set from elsewhere
    public int missionLength; // to be set from elsewhere
    public string hubExit; // to be set from elsewhere
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

    void Start()
    {
        // to-do: instantiate this information variably
        missionName = "Beginnings";
        missionLength = 2;
        currentLevel = 0;
        levelPrefab = Resources.Load<GameObject>("Prefabs/Level");
        NextLevel();
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
            // to-do: exit player to hub and start hub logic
        }
    }
}
