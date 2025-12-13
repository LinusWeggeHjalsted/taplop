using UnityEngine;
using UnityEngine.UI;

public class OverwriteCloneButtonScript : MonoBehaviour
{
    public Button button;

    public void OnActivate()
    {
        PlayerDataScript.CloneData newCloneData = new PlayerDataScript.CloneData();
        newCloneData.totalSalvage = MissionLogicScript.Instance.totalSalvage;
        newCloneData.turnsToComplete = MissionLogicScript.Instance.totalTurns;
        string missionName = MissionLogicScript.Instance.missionName;
        PlayerDataScript.Instance.allCloneData[missionName] = newCloneData;
        // to-do - add popup to tell the player the new clone was saved
    }

    void Start()
    {
        button = this.GetComponent<Button>();
        button.onClick.AddListener(OnActivate);
    }
}
