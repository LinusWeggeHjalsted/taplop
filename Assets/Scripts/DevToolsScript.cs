using UnityEngine;
using UnityEngine.InputSystem;

public class DevToolsScript : MonoBehaviour
{
    public void CompleteLevel()
    {
        GameObject missionLogic = GameObject.Find("Mission Logic");
        if (missionLogic != null)
        {
            MissionLogicScript missionLogicScript = missionLogic.GetComponent<MissionLogicScript>();
            missionLogicScript.currentLevel += 1;
            missionLogicScript.NextLevel();
        }
    }

    void Update()
    {
        Keyboard keyboard = Keyboard.current;
        if (keyboard == null) return;
        if ((keyboard.leftCtrlKey.isPressed || keyboard.rightCtrlKey.isPressed) && keyboard.enterKey.wasPressedThisFrame)
        {
            CompleteLevel();
        }
    }
}
