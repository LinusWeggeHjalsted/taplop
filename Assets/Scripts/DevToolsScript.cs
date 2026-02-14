using UnityEngine;
using UnityEngine.InputSystem;

public class DevToolsScript : MonoBehaviour
{
    public void CompleteLevel()
    {
        if (MissionLogicScript.Instance != null)
        {
            MissionLogicScript missionLogicScript = MissionLogicScript.Instance;
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
